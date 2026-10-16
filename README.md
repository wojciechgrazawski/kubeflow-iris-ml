# Kubeflow Iris ML

A local end-to-end ML example on **OrbStack Kubernetes**. Kubeflow Pipelines trains and publishes an Iris classifier to SeaweedFS (S3-compatible storage), and KServe serves predictions through a custom scikit-learn API.

## Table of contents

- [Architecture](#architecture)
- [Repository files](#repository-files)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Tests](#tests)
- [Run the training pipeline](#run-the-training-pipeline)
- [Deploy and call the model](#deploy-and-call-the-model)
- [Useful commands](#useful-commands)
- [Troubleshooting and cleanup](#troubleshooting-and-cleanup)

## Architecture

```text
Kubeflow Pipelines
  prepare_data -> train_model -> evaluate_model -> publish_model
                                                    |
                                                    v
                                       SeaweedFS / S3
                                  model.joblib + manifest.json
                                                    ^
                                                    | model loaded at startup
Client -> KServe InferenceService -> Custom FastAPI + scikit-learn predictor
```

- **Kubeflow Pipelines 2.17.0** orchestrates the training workflow.
- **SeaweedFS** stores versioned model artifacts in the `mlpipeline` bucket.
- **KServe Standard v0.20.0** exposes the `iris-classifier` InferenceService.
- **Custom predictor** loads the selected model from S3-compatible storage and returns predictions, class names, and confidence scores.

## Repository files

```text
.
├── automation/
│   ├── Dockerfile                  # Image for submitting pipeline runs from Kubernetes
│   ├── config.py                   # Pipeline submission configuration
│   └── submit.py                   # Submits the compiled pipeline to KFP
├── k8s/
│   ├── pipeline-submit-job.yaml    # Job that submits a pipeline run
│   └── iris-inferenceservice.yaml  # KServe InferenceService configuration
├── pipeline/
│   ├── compile.py                  # Compiles the pipeline YAML
│   └── iris_pipeline.py             # Training pipeline definition
├── serving/
│   ├── Dockerfile                  # Custom predictor image
│   └── model.py                    # Prediction server and model loading
├── tests/
│   ├── test_kserve.py              # KServe manifest/configuration tests
│   ├── test_pipeline.py             # Pipeline compilation/structure tests
│   └── integration/
│       └── test_kserve_live.py     # Live endpoint integration test
├── Makefile                        # Environment, tests, install, run and cleanup targets
├── pytest.ini                      # Pytest configuration and integration marker
├── requirements-dev.txt             # Local development and test dependencies
├── requirements-pipeline.txt        # Pipeline compilation/runtime dependencies
├── requirements-automation.txt      # In-cluster submission runner dependencies
└── README.md
```

Generated files and directories such as `.venv/`, `.build/`, `.pytest_cache/`, and `__pycache__/` are not source files.

## Prerequisites

Install and verify:

- OrbStack with a running Kubernetes cluster
- `kubectl` pointed at the intended cluster
- Docker
- Python 3.12 with `venv`
- `make`
- SeaweedFS S3 access, the `mlpipeline` bucket, and the expected credentials

Check your cluster before installing anything:

```bash
kubectl config current-context
kubectl get nodes
```

## Quick start

### 1. Install Kubeflow Pipelines and KServe

```bash
make install-all
```

Or install them separately:

```bash
make install-kubeflow
make install-kserve
```

Check status:

```bash
make clean-status
kubectl get pods -n kubeflow
kubectl get pods -n kserve
```

The installation targets install Kubeflow Pipelines and KServe. Verify that SeaweedFS is running, that the `mlpipeline` bucket exists, and that its credentials are configured before running training or serving.

### 2. Configure model storage

The model is published under a versioned path like:

```text
s3://mlpipeline/models/iris-classifier/versions/v1/
  model.joblib
  manifest.json
```

Check that the serving manifest matches your environment. The default configuration expects:

| Setting | Expected value |
|---|---|
| S3 endpoint | `http://seaweedfs.kubeflow.svc.cluster.local:9000` |
| Bucket | `mlpipeline` |
| Model | `iris-classifier` |
| Model version | `v1` (must exist in storage) |
| Credentials Secret | `mlpipeline-minio-artifact` in `kubeflow` |
| Secret keys | `accesskey`, `secretkey` |

The predictor receives the Secret values as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`; `S3_ENDPOINT` specifies the endpoint URL. Check that the Secret exists without displaying its values:

```bash
kubectl get secret mlpipeline-minio-artifact -n kubeflow
```

Do not commit credentials to source control. The current serving manifest does not require the `iris-kserve-sa` ServiceAccount.

### 3. Set up Python and run tests

The Makefile creates `.venv` automatically and runs Python commands through it. You do **not** need to activate the environment manually.

```bash
make install
make test
```

## Tests

| Command | What it runs | Live KServe required? |
|---|---|---|
| `make test` | All non-integration tests | No |
| `make test-fast` | Same non-integration suite | No |
| `make test-kserve` | KServe manifest/configuration tests | No |
| `make test-pipeline` | Pipeline compilation and structure tests | No |
| `make test-integration` | Live KServe integration test | Yes |
| `make test-all` | All tests, including integration | Yes |

For a live integration test, deploy a ready predictor and start port forwarding in one terminal:

```bash
make kserve-port-forward
```

Then, in another terminal:

```bash
make test-integration
```

The test calls `http://localhost:8082/v1/models/iris-classifier:predict`. Override the endpoint if needed:

```bash
KSERVE_URL=http://localhost:8082/v1/models/iris-classifier:predict make test-integration
```

`make test-all` includes integration tests, so it also needs a reachable endpoint. The tests are already passing in the current project setup.

## Run the training pipeline

Run:

```bash
make run-pipeline
```

This target:

1. Compiles the Kubeflow pipeline.
2. Builds the `iris-pipeline-runner:local` submission image.
3. Replaces the previous `iris-pipeline-submit` Job, if present.
4. Creates a Kubernetes Job that submits the run to Kubeflow Pipelines.
5. Waits for the submission Job and prints its logs.

The pipeline submission Job completing means it submitted the run successfully; check the Kubeflow Pipelines UI to confirm the **pipeline run itself** finished successfully.

```bash
# Check the submission Job
make pipeline-status
make pipeline-logs

# Open the Kubeflow Pipelines UI; keep this command running
make kubeflow-ui
```

The UI is available at [http://localhost:8080](http://localhost:8080) while port forwarding is running.

The pipeline prepares data, trains a scikit-learn `LogisticRegression` model, evaluates it, and publishes `model.joblib` and `manifest.json` to SeaweedFS. Configure the predictor to use a model version that actually exists in the bucket.

## Deploy and call the model

Build and deploy the custom predictor:

```bash
make build-predictor
make deploy-kserve
```

Before deployment, verify the model version and S3 settings, Secret, and image availability to the local cluster. Then check readiness:

```bash
kubectl get inferenceservice iris-classifier -n kubeflow
kubectl describe inferenceservice iris-classifier -n kubeflow
kubectl get pods -n kubeflow
```

Start port forwarding in one terminal:

```bash
make kserve-port-forward
```

In another terminal, send a sample request:

```bash
make kserve-predict
```

The API endpoint is `http://localhost:8082/v1/models/iris-classifier:predict`. Predictions and confidence values depend on the trained model and input data.

## Useful commands

```bash
make help                  # List Makefile targets
make check-cluster         # Check Kubernetes connectivity and nodes
make install-all           # Install Kubeflow Pipelines and KServe
make compile               # Compile the pipeline
make run-pipeline          # Submit a pipeline run
make pipeline-status       # Inspect the submission Job
make pipeline-logs         # Print submission Job logs
make build-predictor       # Build the custom predictor image
make deploy-kserve         # Deploy predictor and wait for readiness
make kserve-status         # Inspect KServe resources
make kserve-logs           # Print predictor logs
make kserve-port-forward   # Forward local port 8082 to the predictor
make kserve-predict        # Send a sample prediction request
make check-kfp-images      # Inspect Kubeflow Pipelines image versions
make verify-kubeflow       # Verify KFP API, driver and launcher versions
make clean-status          # Inspect Kubeflow and KServe resources
make clean-python          # Remove .venv and local Python test caches
```

## Troubleshooting and cleanup

### InferenceService is not ready

```bash
kubectl describe inferenceservice iris-classifier -n kubeflow
kubectl get pods -n kubeflow
kubectl get events -n kubeflow --sort-by=.lastTimestamp
make kserve-logs
```

Check image-pull errors, Secret references, endpoint settings, network access, and model-download errors.

### Model download fails

- Confirm the selected version exists in SeaweedFS.
- Confirm both `model.joblib` and `manifest.json` are present.
- Check `S3_ENDPOINT`, bucket name, Secret name, and Secret key names.
- Ensure `MODEL_URI` and `MODEL_VERSION` refer to the same version.

### Local prediction request fails

- Make sure `make kserve-port-forward` is still running.
- Confirm the InferenceService is Ready and the URL uses port `8082`.

### Cleanup warning

Before cleanup, check the active context and inspect the command:

```bash
kubectl config current-context
make -n clean-ml
```

**Caution:** `make clean-ml` deletes the `kubeflow` and `kserve` namespaces and selected KServe admission webhook configurations. It can remove shared workloads and persistent data. Use it only on a disposable development cluster after reviewing the Makefile.

## Security

- Never commit S3 keys or other credentials.
- Use Kubernetes Secrets or an approved secret-management system.
- Never print Secret values in logs or terminal output.
- Limit access to the model bucket and Kubernetes namespaces.
