# Local monitoring package

This package installs Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics into the local Kubernetes cluster using the `kube-prometheus-stack` Helm chart.

The chart version is pinned in the root Makefile (`MONITORING_CHART_VERSION`, currently `92.7.0`). OrbStack-specific resource settings live in `monitoring/helm/values-orbstack.yaml`.

This is a development configuration, not a production high-availability setup. Prometheus retains three days of metrics and uses ephemeral storage; its time series are lost if the Prometheus pod is recreated. Grafana persistence is disabled.

## Prerequisites

- OrbStack Kubernetes running
- `kubectl` configured for the intended local cluster
- Helm 3
- `make`

Check the active context before installation:

```bash
kubectl config current-context
kubectl get nodes
helm version
```

Do not install this stack while your current context points at a shared or production cluster.

## Render before installing

From the project root:

```bash
make render-monitoring
```

This renders the pinned chart to `.build/monitoring/helm-rendered.yaml` without applying resources to Kubernetes. Review the generated manifest if you want to inspect the chart output.

## Install and verify

```bash
make install-monitoring
make verify-monitoring
make monitoring-status
```

The install target runs the same cluster check used by Kubeflow/KServe targets, creates the dedicated `monitoring` namespace, installs/upgrades the pinned Helm release, waits for readiness, and then verifies the release. The connectivity check does not prove the context is OrbStack, so check the context manually before installation.

## Open Grafana

Run this in a terminal and leave it running:

```bash
make monitoring-grafana
```

Open <http://localhost:3000>. Get the generated admin password in another terminal:

```bash
make monitoring-grafana-password
```

Username: `admin`.

## Open Prometheus

In another terminal:

```bash
make monitoring-prometheus
```

Open <http://localhost:9090> and query `up` to inspect scrape targets.

## What is monitored initially?

- Kubernetes node and pod CPU/memory metrics
- Pod restarts and workload/deployment state
- Kubernetes component metrics that are exposed by the local cluster
- Built-in Kubernetes dashboards in Grafana

This is the infrastructure baseline. Application-specific prediction latency, request/error counts, model load failures, and Kubeflow pipeline metrics require additional instrumentation and scrape configuration; they are not assumed to be available just because this stack is installed.

## Uninstall

```bash
make uninstall-monitoring
```

This prompts for confirmation, removes the Helm release, and deletes the `monitoring` namespace, including resources and any monitoring data stored there. It does not delete the `kubeflow` or `kserve` namespaces.
