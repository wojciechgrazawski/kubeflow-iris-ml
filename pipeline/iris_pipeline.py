
from kfp import dsl, kubernetes
from kfp.dsl import Dataset, Input, Metrics, Model, Output, OutputPath


@dsl.component(
    base_image="python:3.11",
    packages_to_install=["scikit-learn", "pandas"],
)
def prepare_data(dataset: Output[Dataset]):
    import os
    import pandas as pd
    from sklearn.datasets import load_iris

    iris = load_iris(as_frame=True)
    frame = iris.frame

    os.makedirs(os.path.dirname(dataset.path), exist_ok=True)
    frame.to_csv(dataset.path, index=False)

    dataset.metadata["format"] = "csv"
    dataset.metadata["target_column"] = "target"
    dataset.metadata["rows"] = len(frame)
    dataset.metadata["class_names"] = iris.target_names.tolist()

    print(f"Prepared dataset: {dataset.path}")
    print(f"Rows: {len(frame)}")


@dsl.component(
    base_image="python:3.11",
    packages_to_install=["scikit-learn", "pandas", "joblib"],
)
def train_model(
        dataset: Input[Dataset],
        model: Output[Model],
):
    import os
    import joblib
    import pandas as pd
    from sklearn.datasets import load_iris
    from sklearn.linear_model import LogisticRegression

    frame = pd.read_csv(dataset.path)
    X = frame.drop(columns=["target"])
    y = frame["target"]

    classifier = LogisticRegression(
        max_iter=500,
        random_state=42,
    )
    classifier.fit(X, y)

    os.makedirs(os.path.dirname(model.path), exist_ok=True)
    joblib.dump(classifier, model.path)

    model.metadata["framework"] = "scikit-learn"
    model.metadata["model_type"] = "LogisticRegression"
    model.metadata["target_column"] = "target"
    model.metadata["feature_names"] = list(X.columns)
    model.metadata["classes"] = [
        int(value) for value in classifier.classes_
    ]
    model.metadata["class_names"] = (
        load_iris().target_names.tolist()
    )

    print(f"Model saved: {model.path}")
    print(f"Training rows: {len(frame)}")


@dsl.component(
    base_image="python:3.11",
    packages_to_install=["scikit-learn", "pandas", "joblib"],
)
def evaluate_model(
        dataset: Input[Dataset],
        model: Input[Model],
        metrics: Output[Metrics],
):
    import json
    import joblib
    import pandas as pd
    from sklearn.metrics import (
        accuracy_score,
        classification_report,
        confusion_matrix,
    )
    from sklearn.model_selection import train_test_split

    frame = pd.read_csv(dataset.path)
    X = frame.drop(columns=["target"])
    y = frame["target"]

    _, X_test, _, y_test = train_test_split(
        X,
        y,
        test_size=0.2,
        random_state=42,
        stratify=y,
    )

    classifier = joblib.load(model.path)
    predictions = classifier.predict(X_test)

    accuracy = float(accuracy_score(y_test, predictions))
    report = classification_report(
        y_test,
        predictions,
        output_dict=True,
        zero_division=0,
    )
    matrix = confusion_matrix(
        y_test, predictions
    ).tolist()

    metrics.log_metric("accuracy", accuracy)
    metrics.log_metric("test_rows", len(y_test))
    metrics.metadata["classification_report"] = report
    metrics.metadata["confusion_matrix"] = matrix

    print(f"Accuracy: {accuracy:.4f}")
    print(json.dumps(report, indent=2))
    print(json.dumps(matrix))

    if accuracy < 0.80:
        raise ValueError(
            f"Model accuracy {accuracy:.4f} is below 0.80"
        )


@dsl.component(
    base_image="python:3.11",
    packages_to_install=["boto3"],
)
def publish_model(
        model: Input[Model],
        model_version: str,
        model_uri: OutputPath(str),
        manifest_uri: OutputPath(str),
):
    import hashlib
    import json
    import os
    from datetime import datetime, timezone

    import boto3

    endpoint_url = os.getenv(
        "S3_ENDPOINT",
        "http://seaweedfs.kubeflow.svc.cluster.local:9000",
    )
    bucket = os.getenv("S3_BUCKET", "mlpipeline")

    access_key = os.environ["AWS_ACCESS_KEY_ID"]
    secret_key = os.environ["AWS_SECRET_ACCESS_KEY"]

    if (
            not model_version
            or "/" in model_version
            or ".." in model_version
    ):
        raise ValueError(
            f"Invalid model version: {model_version!r}"
        )

    prefix = (
        f"models/iris-classifier/versions/{model_version}"
    )
    model_key = f"{prefix}/model.joblib"
    manifest_key = f"{prefix}/manifest.json"

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint_url,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="us-east-1",
    )

    s3.head_bucket(Bucket=bucket)

    with open(model.path, "rb") as file:
        model_bytes = file.read()

    model_sha256 = hashlib.sha256(model_bytes).hexdigest()

    s3.put_object(
        Bucket=bucket,
        Key=model_key,
        Body=model_bytes,
        ContentType="application/octet-stream",
    )

    published_model_uri = f"s3://{bucket}/{prefix}/"
    published_manifest_uri = f"s3://{bucket}/{manifest_key}"

    manifest = {
        "model_name": "iris-classifier",
        "model_version": model_version,
        "framework": "scikit-learn",
        "model_type": "LogisticRegression",
        "model_file": "model.joblib",
        "model_sha256": model_sha256,
        "model_uri": published_model_uri,
        "manifest_uri": published_manifest_uri,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "s3_endpoint": endpoint_url,
        "features": [
            "sepal length (cm)",
            "sepal width (cm)",
            "petal length (cm)",
            "petal width (cm)",
        ],
        "classes": [0, 1, 2],
        "class_names": {
            "0": "setosa",
            "1": "versicolor",
            "2": "virginica",
        },
    }

    s3.put_object(
        Bucket=bucket,
        Key=manifest_key,
        Body=json.dumps(manifest, indent=2).encode("utf-8"),
        ContentType="application/json",
    )

    with open(model_uri, "w", encoding="utf-8") as file:
        file.write(published_model_uri)

    with open(manifest_uri, "w", encoding="utf-8") as file:
        file.write(published_manifest_uri)

    print(f"Model uploaded: s3://{bucket}/{model_key}")
    print(f"Manifest uploaded: {published_manifest_uri}")
    print(f"KServe storage URI: {published_model_uri}")


@dsl.pipeline(
    name="iris-ml-pipeline",
    description=(
            "Prepare Iris data, train a classifier, evaluate it, "
            "and publish the model to SeaweedFS S3."
    ),
)
def iris_ml_pipeline(model_version: str = "v1"):
    data_task = prepare_data()

    train_task = train_model(
        dataset=data_task.outputs["dataset"],
    )

    evaluate_task = evaluate_model(
        dataset=data_task.outputs["dataset"],
        model=train_task.outputs["model"],
    )

    publish_task = publish_model(
        model=train_task.outputs["model"],
        model_version=model_version,
    )

    publish_task.after(evaluate_task)

    kubernetes.use_secret_as_env(
        publish_task,
        secret_name="mlpipeline-minio-artifact",
        secret_key_to_env={
            "accesskey": "AWS_ACCESS_KEY_ID",
            "secretkey": "AWS_SECRET_ACCESS_KEY",
        },
    )

    publish_task.set_env_variable(
        "S3_ENDPOINT",
        "http://seaweedfs.kubeflow.svc.cluster.local:9000",
    )
    publish_task.set_env_variable("S3_BUCKET", "mlpipeline")


if __name__ == "__main__":
    from kfp import compiler

    compiler.Compiler().compile(
        pipeline_func=iris_ml_pipeline,
        package_path="pipeline/iris_pipeline.yaml",
    )
