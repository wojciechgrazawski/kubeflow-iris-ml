# Kubeflow Iris ML

A local end-to-end machine learning example running on **OrbStack Kubernetes**.

Kubeflow Pipelines trains and publishes an Iris classifier to SeaweedFS (S3-compatible storage). KServe loads the model and exposes an API for predictions. Prometheus and Grafana provide monitoring.

## Architecture

```text
Kubeflow Pipelines
  prepare_data → train_model → evaluate_model → publish_model
                                                    |
                                                    v
                                          SeaweedFS / S3
                                          model.joblib
                                          manifest.json
                                                    |
                                                    v
Client → KServe InferenceService → FastAPI + scikit-learn
```

**Main components**

- **Kubeflow Pipelines 2.17.0** — orchestrates model training.
- **SeaweedFS** — stores versioned model artifacts in the `mlpipeline` bucket.
- **KServe Standard v0.20.0** — serves the `iris-classifier` model.
- **Custom predictor** — loads the model and returns predictions, class names, and confidence scores.
- **Prometheus and Grafana** — collect and display inference metrics.

## Repository structure

```text
automation/     Pipeline submission code
k8s/            Kubernetes Job and KServe manifests
pipeline/       Pipeline definition and compilation
serving/        Custom predictor and Dockerfile
monitoring/     Helm values, ServiceMonitor and Grafana dashboard
scripts/        Metrics smoke test
tests/          Unit, configuration and integration tests
Makefile        Development and deployment commands
```

## Prerequisites

Install:

- OrbStack with Kubernetes enabled
- `kubectl`, Docker and `make`
- Python 3.12 with `venv`
- SeaweedFS S3 access, the `mlpipeline` bucket and valid credentials

Verify your Kubernetes context before making changes:

```bash
kubectl config current-context
kubectl get nodes
```

## Quick start

### 1. Install Kubeflow Pipelines and KServe

```bash
make install-all
```

Alternatively, install them separately:

```bash
make install-kubeflow
make install-kserve
```

Check the installation:

```bash
make clean-status
kubectl get pods -n kubeflow
kubectl get pods -n kserve
```

These targets install Kubeflow Pipelines and KServe. Make sure SeaweedFS is running, the `mlpipeline` bucket exists, and its credentials are configured before training or serving.

### 2. Configure model storage

The default model location is:

```text
s3://mlpipeline/models/iris-classifier/versions/v1/
├── model.joblib
└── manifest.json
```

The serving configuration expects:

| Setting | Value |
|---|---|
| S3 endpoint | `http://seaweedfs.kubeflow.svc.cluster.local:9000` |
| Bucket | `mlpipeline` |
| Model | `iris-classifier` |
| Version | `v1` |
| Kubernetes Secret | `mlpipeline-minio-artifact` in `kubeflow` |
| Secret keys | `accesskey`, `secretkey` |

The predictor reads the credentials through `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, and uses `S3_ENDPOINT` for the endpoint URL.

Check that the Secret exists without displaying its values:

```bash
kubectl get secret mlpipeline-minio-artifact -n kubeflow
```

Ensure the selected model version exists and matches the serving configuration. **Never commit credentials to source control.**

### 3. Install development dependencies and run tests

The Makefile manages the local `.venv` automatically.

```bash
make install
make test
```

## Run the training pipeline

Submit a pipeline run:

```bash
make run-pipeline
```

This compiles the pipeline, builds the submission image, and creates a Kubernetes Job that submits the run to Kubeflow Pipelines.

Check the submission Job:

```bash
make pipeline-status
make pipeline-logs
```

Open the Kubeflow Pipelines UI in a separate terminal:

```bash
make kubeflow-ui
```

Open [http://localhost:8080](http://localhost:8080) while port forwarding is running.

**Important:** A successful submission Job does not guarantee that the pipeline run succeeded. Check the run status in the UI.

The pipeline prepares the data, trains and evaluates a scikit-learn `LogisticRegression` model, then publishes `model.joblib` and `manifest.json` to SeaweedFS.

## Deploy and call the model

Build and deploy the predictor:

```bash
make build-predictor
make deploy-kserve
```

Check the InferenceService and pods:

```bash
kubectl get inferenceservice iris-classifier -n kubeflow
kubectl describe inferenceservice iris-classifier -n kubeflow
kubectl get pods -n kubeflow
```

Start port forwarding in one terminal:

```bash
make kserve-port-forward
```

Send a sample prediction from another terminal:

```bash
make kserve-predict
```

The default endpoint is:

```text
http://localhost:8082/v1/models/iris-classifier:predict
```

Before deployment, verify the model version, S3 settings, Secret, and predictor image availability to the local cluster.

## Tests

| Command | Purpose | Live KServe required? |
|---|---|---|
| `make test` | Run non-integration tests | No |
| `make test-fast` | Run the fast non-integration suite | No |
| `make test-kserve` | Test KServe configuration | No |
| `make test-pipeline` | Test pipeline compilation and structure | No |
| `make test-integration` | Test the live inference endpoint | Yes |
| `make test-all` | Run all tests, including integration | Yes |

For integration tests, start port forwarding:

```bash
make kserve-port-forward
```

Then run in another terminal:

```bash
make test-integration
```

Override the endpoint if needed:

```bash
KSERVE_URL=http://localhost:8082/v1/models/iris-classifier:predict \
  make test-integration
```

## Local observability

The project uses **kube-prometheus-stack** for Prometheus and Grafana. Helm installs the monitoring stack, while Kustomize applies the project-specific ServiceMonitor and dashboard.

### Install or update monitoring

Check your Kubernetes context first:

```bash
kubectl config current-context
kubectl get nodes
```

Render the Helm configuration without installing it:

```bash
make render-monitoring
```

Install or upgrade the stack and apply the project resources:

```bash
make install-monitoring
```

If you only changed the dashboard or ServiceMonitor, apply those changes without reinstalling Helm:

```bash
make apply-monitoring-config
```

### Open Grafana and Prometheus

Run each command in a separate terminal and leave it running.

**Grafana**

```bash
make monitoring-grafana
make monitoring-grafana-password
```

Open [http://localhost:3000](http://localhost:3000) and sign in with the configured admin credentials.

**Prometheus**

```bash
make monitoring-prometheus
```

Open [http://localhost:9090](http://localhost:9090) and query `up` to inspect scrape targets.

You can override the local Grafana port, for example:

```bash
make monitoring-grafana MONITORING_GRAFANA_LOCAL_PORT=3001
```

### Iris inference metrics

The ServiceMonitor at `monitoring/kustomize/servicemonitor/iris-classifier-servicemonitor.yaml` scrapes the predictor's `/metrics` endpoint every 15 seconds.

The Grafana dashboard is defined in:

`monitoring/kustomize/grafana-dashboard/iris-classifier-dashboard.json`

It displays:

- Prediction request rate
- Average prediction-stage latency
- p95 prediction-stage latency
- Predictor process memory
- Predictions by Iris category, if the custom `iris_predictions_total` metric is implemented and exposed

The category panel requires the custom metric to exist in Prometheus; a dashboard query cannot create a missing metric.

Check monitoring resources:

```bash
make monitoring-status
make verify-monitoring
kubectl get servicemonitor -n kubeflow iris-classifier
kubectl get configmap -n monitoring iris-classifier-dashboard
kubectl get pods -n monitoring
```

### Test inference metrics

With the predictor deployed and ready, run:

```bash
bash scripts/test-kserve-metrics.sh
```

The script generates inference traffic and checks the predictor metrics and Prometheus queries. It may wait for scraping and rate-query windows to collect enough data.

## Useful commands

| Command | Purpose |
|---|---|
| `make help` | List available Makefile targets |
| `make check-cluster` | Check cluster connectivity |
| `make compile` | Compile the pipeline |
| `make kserve-status` | Inspect KServe resources |
| `make kserve-logs` | View predictor logs |
| `make kserve-predict` | Send a sample prediction |
| `make monitoring-status` | Inspect monitoring workloads |
| `make apply-monitoring-config` | Apply dashboard and ServiceMonitor changes |
| `make check-kfp-images` | Inspect Kubeflow Pipelines image versions |
| `make verify-kubeflow` | Verify KFP API, driver and launcher versions |
| `make clean-python` | Remove local Python environment and test caches |

Use `make help` for the full list of supported targets.

## Troubleshooting

### InferenceService is not ready

```bash
kubectl describe inferenceservice iris-classifier -n kubeflow
kubectl get pods -n kubeflow
kubectl get events -n kubeflow --sort-by=.lastTimestamp
make kserve-logs
```

Check image-pull errors, Secret references, S3 connectivity, model-download errors and pod events.

### Model download fails

- Confirm the selected version exists in SeaweedFS.
- Verify that `model.joblib` and `manifest.json` are present.
- Check `S3_ENDPOINT`, the bucket, Secret name and Secret key names.
- Ensure `MODEL_URI` and `MODEL_VERSION` refer to the intended model version.

### Prediction request fails

- Confirm that `make kserve-port-forward` is still running.
- Check that the InferenceService is ready.
- Verify the endpoint and local port `8082`.

## Cleanup and security

Before cleanup, check the active cluster and inspect the Makefile target:

```bash
kubectl config current-context
make -n clean-ml
```

**Caution:** `make clean-ml` deletes the `kubeflow` and `kserve` namespaces and selected KServe admission webhook configurations. It may remove shared workloads and persistent data. Use it only on a disposable development cluster after reviewing the command.

To remove monitoring, run:

```bash
make uninstall-monitoring
```

This target requires confirmation and deletes the entire `monitoring` namespace, including workloads and data stored there.

Security reminders:

- Never commit credentials or print Secret values.
- Use Kubernetes Secrets or an approved secret-management system.
- Restrict access to model storage and Kubernetes namespaces.
