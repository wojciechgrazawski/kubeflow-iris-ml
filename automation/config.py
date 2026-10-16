
import os


KFP_ENDPOINT = os.getenv(
    "KFP_ENDPOINT",
    "http://ml-pipeline.kubeflow.svc.cluster.local:8888",
)

EXPERIMENT_NAME = os.getenv(
    "EXPERIMENT_NAME",
    "iris-ml-experiment",
)

RUN_NAME = os.getenv(
    "RUN_NAME",
    "iris-ml-run",
)

PIPELINE_TIMEOUT_SECONDS = int(
    os.getenv("PIPELINE_TIMEOUT_SECONDS", "3600")
)
