
from pathlib import Path

import yaml


PROJECT_ROOT = Path(__file__).resolve().parents[1]
KSERVE_MANIFEST = PROJECT_ROOT / "k8s" / "iris-inferenceservice.yaml"

EXPECTED_IMAGE = "iris-custom-predictor:0.1"
EXPECTED_NAMESPACE = "kubeflow"
EXPECTED_MODEL_NAME = "iris-classifier"
EXPECTED_MODEL_VERSION = "v1"
EXPECTED_SECRET = "mlpipeline-minio-artifact"
EXPECTED_S3_ENDPOINT = (
    "http://seaweedfs.kubeflow.svc.cluster.local:9000"
)


def load_manifest() -> dict:
    assert KSERVE_MANIFEST.is_file(), (
        f"KServe manifest not found: {KSERVE_MANIFEST}"
    )

    manifest = yaml.safe_load(
        KSERVE_MANIFEST.read_text(encoding="utf-8")
    )

    assert isinstance(manifest, dict)
    return manifest


def get_predictor_container(manifest: dict) -> dict:
    predictor = manifest["spec"]["predictor"]

    containers = predictor.get("containers", [])
    assert containers, "No custom predictor container is configured"

    matching = [
        container
        for container in containers
        if container.get("image") == EXPECTED_IMAGE
    ]

    assert matching, (
        f"Expected predictor image {EXPECTED_IMAGE!r}; "
        f"configured images: "
        f"{[c.get('image') for c in containers]}"
    )

    return matching[0]


def get_environment(container: dict) -> dict[str, dict]:
    return {
        item["name"]: item
        for item in container.get("env", [])
    }


def test_inferenceservice_identity() -> None:
    manifest = load_manifest()

    assert manifest["apiVersion"] == "serving.kserve.io/v1beta1"
    assert manifest["kind"] == "InferenceService"
    assert manifest["metadata"]["name"] == EXPECTED_MODEL_NAME
    assert manifest["metadata"]["namespace"] == EXPECTED_NAMESPACE


def test_uses_custom_predictor_not_builtin_model_storage() -> None:
    manifest = load_manifest()
    predictor = manifest["spec"]["predictor"]

    # The application downloads the model from SeaweedFS itself.
    assert "model" not in predictor
    assert "serviceAccountName" not in predictor

    container = get_predictor_container(manifest)
    assert container["imagePullPolicy"] == "IfNotPresent"


def test_model_configuration_is_consistent() -> None:
    manifest = load_manifest()
    container = get_predictor_container(manifest)
    env = get_environment(container)

    assert env["MODEL_NAME"]["value"] == EXPECTED_MODEL_NAME
    assert env["MODEL_VERSION"]["value"] == EXPECTED_MODEL_VERSION

    model_uri = env["MODEL_URI"]["value"].rstrip("/")
    expected_suffix = (
        f"/models/{EXPECTED_MODEL_NAME}/versions/"
        f"{EXPECTED_MODEL_VERSION}"
    )

    assert model_uri.startswith("s3://")
    assert model_uri.endswith(expected_suffix)


def test_s3_endpoint_is_configured() -> None:
    manifest = load_manifest()
    container = get_predictor_container(manifest)
    env = get_environment(container)

    assert env["S3_ENDPOINT"]["value"] == EXPECTED_S3_ENDPOINT


def test_s3_credentials_come_from_kubernetes_secret() -> None:
    manifest = load_manifest()
    container = get_predictor_container(manifest)
    env = get_environment(container)

    expected_keys = {
        "AWS_ACCESS_KEY_ID": "accesskey",
        "AWS_SECRET_ACCESS_KEY": "secretkey",
    }

    for variable, expected_key in expected_keys.items():
        assert variable in env, f"Missing environment variable: {variable}"

        variable_config = env[variable]

        assert "value" not in variable_config, (
            f"{variable} must not contain a plaintext credential"
        )

        secret_ref = (
            variable_config.get("valueFrom", {}).get("secretKeyRef")
        )

        assert secret_ref is not None, (
            f"{variable} must reference a Kubernetes Secret"
        )
        assert secret_ref["name"] == EXPECTED_SECRET
        assert secret_ref["key"] == expected_key


def test_predictor_has_resource_requests_and_limits() -> None:
    manifest = load_manifest()
    container = get_predictor_container(manifest)

    resources = container.get("resources", {})
    requests = resources.get("requests", {})
    limits = resources.get("limits", {})

    assert requests.get("cpu"), "CPU request must be configured"
    assert requests.get("memory"), "Memory request must be configured"
    assert limits.get("memory"), "Memory limit must be configured"
