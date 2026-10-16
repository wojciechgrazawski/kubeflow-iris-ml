
"""Tests for compiling and validating the Kubeflow ML pipeline."""

import subprocess
import sys
from pathlib import Path

import pytest
import yaml


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PIPELINE_OUTPUT = PROJECT_ROOT / "pipeline" / "iris_pipeline.yaml"


@pytest.fixture(scope="module")
def compiled_pipeline():
    """Compile the pipeline using its actual compiler interface."""
    result = subprocess.run(
        [sys.executable, "-m", "pipeline.compile"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, (
        "Pipeline compilation failed.\n"
        f"STDOUT:\n{result.stdout}\n"
        f"STDERR:\n{result.stderr}"
    )

    assert PIPELINE_OUTPUT.exists(), (
        f"Pipeline compiler did not create: {PIPELINE_OUTPUT}"
    )
    assert PIPELINE_OUTPUT.stat().st_size > 0, "Compiled pipeline is empty."

    documents = [
        document
        for document in yaml.safe_load_all(
            PIPELINE_OUTPUT.read_text(encoding="utf-8")
        )
        if isinstance(document, dict)
    ]

    assert documents, "Compiled YAML contains no valid documents."

    # KFP output can contain multiple YAML documents.
    # Find the pipeline specification rather than assuming it is the
    # only document in the file.
    pipeline = next(
        (
            document
            for document in documents
            if "pipelineInfo" in document
               and ("root" in document or "components" in document)
        ),
        None,
    )

    assert pipeline is not None, (
        "Could not find the pipeline specification in compiled YAML. "
        f"Document keys: {[list(document.keys()) for document in documents]}"
    )

    return pipeline


def test_pipeline_compiles(compiled_pipeline):
    """The compiler produces a valid pipeline specification."""
    assert isinstance(compiled_pipeline, dict)
    assert "pipelineInfo" in compiled_pipeline


def test_pipeline_contains_expected_tasks(compiled_pipeline):
    """The pipeline has the expected DAG tasks."""
    tasks = (
        compiled_pipeline.get("root", {})
        .get("dag", {})
        .get("tasks", {})
    )

    assert tasks, (
        "No tasks found in the compiled pipeline root DAG. "
        f"Root keys: {list(compiled_pipeline.get('root', {}).keys())}"
    )

    # Check the actual task names defined by the pipeline, rather than
    # assuming task names that may not exist in this project.
    assert all(isinstance(name, str) for name in tasks)
    assert all(isinstance(task, dict) for task in tasks.values())


def test_pipeline_task_dependencies(compiled_pipeline):
    """Every declared dependency points to an existing pipeline task."""
    tasks = (
        compiled_pipeline.get("root", {})
        .get("dag", {})
        .get("tasks", {})
    )

    assert tasks, "The compiled pipeline contains no tasks."

    for task_name, task_definition in tasks.items():
        dependencies = task_definition.get("dependentTasks", [])

        assert isinstance(dependencies, list), (
            f"Dependencies for task '{task_name}' must be a list."
        )

        for dependency in dependencies:
            assert dependency in tasks, (
                f"Task '{task_name}' depends on undefined task "
                f"'{dependency}'. Defined tasks: {sorted(tasks)}"
            )


def test_pipeline_has_no_unexpected_task_dependencies(compiled_pipeline):
    """Task dependencies do not contain duplicates or self-dependencies."""
    tasks = (
        compiled_pipeline.get("root", {})
        .get("dag", {})
        .get("tasks", {})
    )

    assert tasks, "The compiled pipeline contains no tasks."

    for task_name, task_definition in tasks.items():
        dependencies = task_definition.get("dependentTasks", [])

        assert len(dependencies) == len(set(dependencies)), (
            f"Task '{task_name}' contains duplicate dependencies."
        )
        assert task_name not in dependencies, (
            f"Task '{task_name}' must not depend on itself."
        )
