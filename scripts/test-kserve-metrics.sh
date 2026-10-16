#!/usr/bin/env bash
set -Eeuo pipefail

# Concurrent load test for the local KServe Iris predictor plus Prometheus checks.
# Run from the repository root:
#   bash scripts/test-kserve-metrics.sh
# Examples:
#   LOAD_REQUESTS=1000 LOAD_CONCURRENCY=20 bash scripts/test-kserve-metrics.sh
#   LOAD_REQUESTS=5000 LOAD_CONCURRENCY=40 LOAD_SAMPLES_PER_REQUEST=5 bash scripts/test-kserve-metrics.sh
# Increase concurrency gradually and monitor predictor CPU/memory in Grafana.

NAMESPACE="${NAMESPACE:-kubeflow}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
PREDICTOR_SERVICE="${PREDICTOR_SERVICE:-iris-classifier-predictor}"
PROMETHEUS_SERVICE="${PROMETHEUS_SERVICE:-monitoring-kube-prometheus-prometheus}"
LOCAL_PREDICTOR_PORT="${LOCAL_PREDICTOR_PORT:-18082}"
LOCAL_PROMETHEUS_PORT="${LOCAL_PROMETHEUS_PORT:-19090}"
LOAD_REQUESTS="${LOAD_REQUESTS:-1000}"
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-20}"
LOAD_SAMPLES_PER_REQUEST="${LOAD_SAMPLES_PER_REQUEST:-3}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-10}"
PROMETHEUS_WAIT_SECONDS="${PROMETHEUS_WAIT_SECONDS:-45}"

PREDICT_URL="http://127.0.0.1:${LOCAL_PREDICTOR_PORT}/v1/models/iris-classifier:predict"
PROMETHEUS_URL="http://127.0.0.1:${LOCAL_PROMETHEUS_PORT}"
PREDICTOR_LOG="$(mktemp)"
PROMETHEUS_LOG="$(mktemp)"
PREDICTOR_PF_PID=""
PROMETHEUS_PF_PID=""

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
cleanup() {
  [[ -z "$PREDICTOR_PF_PID" ]] || kill "$PREDICTOR_PF_PID" 2>/dev/null || true
  [[ -z "$PROMETHEUS_PF_PID" ]] || kill "$PROMETHEUS_PF_PID" 2>/dev/null || true
  rm -f "$PREDICTOR_LOG" "$PROMETHEUS_LOG"
}
trap cleanup EXIT INT TERM

for cmd in kubectl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done
for name in LOAD_REQUESTS LOAD_CONCURRENCY LOAD_SAMPLES_PER_REQUEST REQUEST_TIMEOUT_SECONDS PROMETHEUS_WAIT_SECONDS; do
  value="${!name}"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )) || die "$name must be a positive integer (got '$value')"
done

port_available() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
}
port_available "$LOCAL_PREDICTOR_PORT" || die "Local predictor port $LOCAL_PREDICTOR_PORT is already in use; override LOCAL_PREDICTOR_PORT"
port_available "$LOCAL_PROMETHEUS_PORT" || die "Local Prometheus port $LOCAL_PROMETHEUS_PORT is already in use; override LOCAL_PROMETHEUS_PORT"

log "Kubernetes context: $(kubectl config current-context)"
kubectl get svc "$PREDICTOR_SERVICE" -n "$NAMESPACE" >/dev/null || die "Predictor service $PREDICTOR_SERVICE not found in namespace $NAMESPACE"
kubectl get svc "$PROMETHEUS_SERVICE" -n "$MONITORING_NAMESPACE" >/dev/null || die "Prometheus service $PROMETHEUS_SERVICE not found in namespace $MONITORING_NAMESPACE"

log "Starting temporary port-forwards"
kubectl port-forward -n "$NAMESPACE" "svc/$PREDICTOR_SERVICE" "${LOCAL_PREDICTOR_PORT}:80" >"$PREDICTOR_LOG" 2>&1 &
PREDICTOR_PF_PID=$!
kubectl port-forward -n "$MONITORING_NAMESPACE" "svc/$PROMETHEUS_SERVICE" "${LOCAL_PROMETHEUS_PORT}:9090" >"$PROMETHEUS_LOG" 2>&1 &
PROMETHEUS_PF_PID=$!

wait_url() {
  local url="$1" label="$2" log_file="$3" tries=45
  until curl -fsS --max-time 2 "$url" >/dev/null 2>&1; do
    kill -0 "$([[ "$label" == "predictor" ]] && echo "$PREDICTOR_PF_PID" || echo "$PROMETHEUS_PF_PID")" 2>/dev/null || {
      echo "Port-forward process for $label exited:" >&2; cat "$log_file" >&2; die "Could not connect to $label"
    }
    tries=$((tries - 1))
    (( tries > 0 )) || { echo "Port-forward log for $label:" >&2; cat "$log_file" >&2; die "Timed out waiting for $label at $url"; }
    sleep 1
  done
}
wait_url "$PROMETHEUS_URL/-/ready" prometheus "$PROMETHEUS_LOG"
wait_url "http://127.0.0.1:${LOCAL_PREDICTOR_PORT}/metrics" predictor "$PREDICTOR_LOG"

log "Checking Prometheus scrape target"
curl -fsSG "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=up{namespace="kubeflow",service="iris-classifier-predictor"}' |
python3 -c 'import json,sys; d=json.load(sys.stdin); rows=d.get("data",{}).get("result",[]); print("Scrape series:", len(rows)); [print("  up =", r["value"][1], r.get("metric",{})) for r in rows]; sys.exit(0 if d.get("status")=="success" and rows else 1)' \
  || die "No matching Prometheus up-series. Check the ServiceMonitor, labels, and scrape status."

log "Starting load: requests=$LOAD_REQUESTS concurrency=$LOAD_CONCURRENCY samples/request=$LOAD_SAMPLES_PER_REQUEST"
export LOAD_REQUESTS LOAD_CONCURRENCY LOAD_SAMPLES_PER_REQUEST REQUEST_TIMEOUT_SECONDS PREDICT_URL
python3 <<'PY'
import concurrent.futures, json, os, statistics, time, urllib.error, urllib.request

total = int(os.environ["LOAD_REQUESTS"])
workers = int(os.environ["LOAD_CONCURRENCY"])
batch_size = int(os.environ["LOAD_SAMPLES_PER_REQUEST"])
timeout = int(os.environ["REQUEST_TIMEOUT_SECONDS"])
url = os.environ["PREDICT_URL"]
examples = [[5.1, 3.5, 1.4, 0.2], [6.0, 2.9, 4.5, 1.5], [6.7, 3.0, 5.2, 2.3]]
payload = json.dumps({"instances": [examples[i % len(examples)] for i in range(batch_size)]}).encode()

def request(index):
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"}, method="POST")
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            body = response.read()
            elapsed = time.perf_counter() - start
            if not 200 <= response.status < 300:
                return index, elapsed, False, f"HTTP {response.status}: {body[:200]!r}"
            try:
                result = json.loads(body)
            except ValueError as exc:
                return index, elapsed, False, f"Invalid JSON: {exc}"
            preds = result.get("predictions") if isinstance(result, dict) else None
            if not isinstance(preds, list) or len(preds) != batch_size:
                return index, elapsed, False, f"Unexpected response shape: {body[:200]!r}"
            return index, elapsed, True, ""
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return index, time.perf_counter() - start, False, str(exc)

start = time.perf_counter()
latencies, failures, successes = [], [], 0
progress_step = max(1, total // 10)
with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
    # executor.map keeps scheduling bounded rather than building a list of all futures.
    for done, result in enumerate(pool.map(request, range(total)), start=1):
        index, elapsed, ok, error = result
        latencies.append(elapsed)
        if ok:
            successes += 1
        else:
            failures.append((index, error))
        if done % progress_step == 0 or done == total:
            print(f"Progress {done}/{total}: success={successes}, failed={len(failures)}", flush=True)

elapsed_total = time.perf_counter() - start
ordered = sorted(latencies)
def percentile(p):
    if not ordered: return float("nan")
    return ordered[min(len(ordered)-1, max(0, int((p / 100) * len(ordered) + 0.999)-1))]
print("\nLoad-test summary")
print(f"  Requests attempted:     {total}")
print(f"  Requests successful:    {successes}")
print(f"  Requests failed:        {len(failures)}")
print(f"  Samples classified:     {successes * batch_size}")
print(f"  Concurrency:            {workers}")
print(f"  Samples per request:    {batch_size}")
print(f"  Total duration:         {elapsed_total:.2f}s")
print(f"  Attempted throughput:   {total / elapsed_total:.2f} req/s")
print(f"  Successful throughput:  {successes / elapsed_total:.2f} req/s")
if ordered:
    print(f"  Mean latency:           {statistics.mean(ordered):.4f}s")
    print(f"  Median latency:         {statistics.median(ordered):.4f}s")
    print(f"  p95 latency:            {percentile(95):.4f}s")
    print(f"  Max latency:            {max(ordered):.4f}s")
if failures:
    print("\nFirst failures:")
    for index, error in failures[:10]: print(f"  request #{index}: {error}")
if failures:
    raise SystemExit(1)
PY

log "Waiting ${PROMETHEUS_WAIT_SECONDS}s for scrape and rate-query windows"
sleep "$PROMETHEUS_WAIT_SECONDS"

prom_query() {
  local title="$1" query="$2" response
  response="$(curl -fsSG "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=$query")" || die "Prometheus query failed: $title"
  printf '\n%s\n' "$title"
  python3 -c 'import json,sys; d=json.load(sys.stdin); rows=d.get("data",{}).get("result",[]); print("  (no series returned)" if not rows else "\n".join("  %s => %s" % (r.get("metric",{}), r.get("value",[None,None])[1]) for r in rows)); sys.exit(0 if d.get("status")=="success" else 1)' <<<"$response"
}
SELECTOR='{namespace="kubeflow",service="iris-classifier-predictor",model_name="iris-classifier"}'
prom_query "Request count series" "request_predict_seconds_count${SELECTOR}"
prom_query "Request rate (requests/second, 5m)" "sum(rate(request_predict_seconds_count${SELECTOR}[5m]))"
prom_query "Average prediction-stage latency (seconds, 5m)" "sum(rate(request_predict_seconds_sum${SELECTOR}[5m])) / sum(rate(request_predict_seconds_count${SELECTOR}[5m]))"
prom_query "p95 prediction-stage latency (seconds, 5m)" "histogram_quantile(0.95, sum by (le) (rate(request_predict_seconds_bucket${SELECTOR}[5m])))"
prom_query "Predictor resident memory (bytes)" 'process_resident_memory_bytes{namespace="kubeflow",service="iris-classifier-predictor"}'

optional="$(curl -fsSG "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (class_name) (increase(iris_predictions_total{namespace="kubeflow",service="iris-classifier-predictor",model_name="iris-classifier"}[15m]))' 2>/dev/null || true)"
printf '\nPredictions by Iris category (optional custom metric)\n'
# This metric is optional. Parse the response defensively so a missing metric or
# malformed/concatenated response never turns an otherwise successful test into a failure.
python3 - "$optional" <<'PY_OPTIONAL'
import json, sys
raw = sys.argv[1].strip()
if not raw:
    print("  Not exposed or no samples in range.")
    raise SystemExit(0)
try:
    decoder = json.JSONDecoder()
    documents = []
    offset = 0
    while offset < len(raw):
        while offset < len(raw) and raw[offset].isspace():
            offset += 1
        if offset >= len(raw):
            break
        document, offset = decoder.raw_decode(raw, offset)
        documents.append(document)
    rows = []
    for document in documents:
        if document.get("status") == "success":
            rows.extend(document.get("data", {}).get("result", []))
    if not rows:
        print("  Not exposed or no samples in range.")
    else:
        for row in rows:
            labels = row.get("metric", {})
            value = row.get("value", [None, "unknown"])[1]
            print(f"  {labels.get('class_name', 'unknown')} => {value}")
except (json.JSONDecodeError, AttributeError, TypeError) as exc:
    print(f"  Optional metric response could not be parsed; skipping ({exc}).")
PY_OPTIONAL

log "Load test and metrics queries completed"
