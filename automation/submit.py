
import json
import os
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from kfp import Client

from automation.config import (
    EXPERIMENT_NAME,
    KFP_ENDPOINT,
    PIPELINE_TIMEOUT_SECONDS,
    RUN_NAME,
)


PROJECT_ROOT = Path(__file__).resolve().parent.parent
PIPELINE_FILE = PROJECT_ROOT / "pipeline" / "iris_pipeline.yaml"

S3_BUCKET = os.getenv("S3_BUCKET", "mlpipeline")
MODEL_NAME = os.getenv("MODEL_NAME", "iris-classifier")
DEFAULT_MODEL_VERSION = os.getenv("MODEL_VERSION", "v1")

SUCCESS_STATES = {"SUCCEEDED", "COMPLETE", "COMPLETED"}

EXPECTED_OUTPUTS = (
    "model_storage_uri",
    "manifest_uri",
    "model_version",
    "accuracy",
)


def to_mapping(value: Any) -> dict:
    """Convert a KFP SDK object to a dictionary where possible."""
    if value is None:
        return {}

    if isinstance(value, Mapping):
        return dict(value)

    for method_name in ("to_dict", "to_dict_or_none"):
        method = getattr(value, method_name, None)

        if callable(method):
            try:
                result = method()
                if isinstance(result, Mapping):
                    return dict(result)
            except Exception:
                pass

    if hasattr(value, "__dict__"):
        return vars(value)

    return {}


def normalize_parameter(value: Any) -> Any:
    """Extract a parameter value from common KFP response formats."""
    if not isinstance(value, Mapping):
        return value

    for key in (
            "parameter_value",
            "string_value",
            "double_value",
            "int_value",
            "value",
    ):
        if key in value and value[key] is not None:
            return value[key]

    return None


def find_outputs(value: Any, depth: int = 0) -> dict:
    """Search nested KFP run responses for pipeline output parameters."""
    if value is None or depth > 12:
        return {}

    if isinstance(value, str):
        text_value = value.strip()

        if text_value.startswith(("{", "[")):
            try:
                return find_outputs(json.loads(text_value), depth + 1)
            except json.JSONDecodeError:
                return {}

        return {}

    if isinstance(value, (list, tuple)):
        found = {}

        for item in value:
            found.update(find_outputs(item, depth + 1))

        return found

    data = to_mapping(value)

    if not data:
        return {}

    found = {}

    for name in EXPECTED_OUTPUTS:
        if name in data:
            result = normalize_parameter(data[name])

            if result is not None:
                found[name] = result

    nested_fields = (
        "pipeline_output_parameters",
        "output_parameters",
        "outputs",
        "output",
        "run",
        "run_details",
        "pipeline_runtime",
        "pipeline_outputs",
        "runtime_config",
        "result",
    )

    for key in nested_fields:
        if key in data:
            found.update(find_outputs(data[key], depth + 1))

    return found


def get_field(value: Any, name: str) -> Any:
    """Read a field from a dictionary or an SDK object."""
    if isinstance(value, Mapping):
        return value.get(name)

    return getattr(value, name, None)


def normalize_state(value: Any) -> str:
    """Normalize a run state to a comparable string."""
    if value is None:
        return "UNKNOWN"

    return str(value).strip().upper().rsplit(".", 1)[-1]


def print_model_outputs(
        outputs: dict,
        run_id: str,
        model_version: str,
) -> None:
    """Print model publication details."""
    version = outputs.get("model_version") or model_version

    expected_uri = (
        f"s3://{S3_BUCKET}/models/{MODEL_NAME}/versions/{version}/"
    )
    expected_manifest_uri = f"{expected_uri}manifest.json"

    model_uri = outputs.get("model_storage_uri") or expected_uri
    manifest_uri = outputs.get("manifest_uri") or expected_manifest_uri
    accuracy = outputs.get("accuracy")

    print("\nModel publication results")
    print("==========================")
    print(f"KServe storage URI: {model_uri}")
    print(f"Manifest URI:       {manifest_uri}")
    print(f"Model version:      {version}")

    if accuracy is not None:
        print(f"Model accuracy:     {accuracy}")
    else:
        print("Model accuracy:     Not exposed as a pipeline output.")

    print(f"Kubeflow run ID:    {run_id}")
    print(
        "\nNote: if the run does not expose these output parameters, "
        "the displayed S3 URIs are derived from configuration and "
        "are not proof that the objects exist."
    )


def main() -> int:
    if not PIPELINE_FILE.is_file():
        print(
            f"ERROR: Compiled pipeline not found: {PIPELINE_FILE}",
            file=sys.stderr,
            flush=True,
        )
        print("Run make compile first.", file=sys.stderr)
        return 1

    model_version = os.getenv(
        "MODEL_VERSION",
        DEFAULT_MODEL_VERSION,
    ).strip()

    if (
            not model_version
            or "/" in model_version
            or ".." in model_version
    ):
        print(
            f"ERROR: Invalid MODEL_VERSION: {model_version!r}",
            file=sys.stderr,
        )
        return 1

    print(f"KFP endpoint: {KFP_ENDPOINT}", flush=True)
    print(f"Pipeline file: {PIPELINE_FILE}", flush=True)
    print(f"Experiment: {EXPERIMENT_NAME}", flush=True)
    print(f"Model version: {model_version}", flush=True)

    try:
        client = Client(host=KFP_ENDPOINT)

        run = client.create_run_from_pipeline_package(
            pipeline_file=str(PIPELINE_FILE),
            arguments={"model_version": model_version},
            run_name=RUN_NAME,
            experiment_name=EXPERIMENT_NAME,
        )

        run_id = get_field(run, "run_id")

        if not run_id:
            print(
                "ERROR: Kubeflow did not return a run ID.",
                file=sys.stderr,
                flush=True,
            )
            return 1

        print(f"Submitted run ID: {run_id}", flush=True)
        print("Waiting for pipeline completion...", flush=True)

        result = client.wait_for_run_completion(
            run_id=run_id,
            timeout=PIPELINE_TIMEOUT_SECONDS,
        )

        state = normalize_state(get_field(result, "state"))

        if state == "UNKNOWN":
            nested_run = get_field(result, "run")
            state = normalize_state(get_field(nested_run, "state"))

        print(f"Final pipeline state: {state}", flush=True)

        if state not in SUCCESS_STATES:
            print(
                f"ERROR: Pipeline did not succeed: {state}",
                file=sys.stderr,
                flush=True,
            )
            print(f"Run ID: {run_id}", file=sys.stderr)
            return 1

        completed_run = client.get_run(run_id)

        outputs = find_outputs(completed_run)
        outputs.update(find_outputs(result))

        print_model_outputs(
            outputs=outputs,
            run_id=run_id,
            model_version=model_version,
        )

        return 0

    except Exception as exc:
        print(
            f"ERROR: Pipeline submission or monitoring failed: {exc}",
            file=sys.stderr,
            flush=True,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
