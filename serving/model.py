"""KServe-native Iris model implementation using the V1 inference protocol."""
from __future__ import annotations

import json
import logging
import os
import tempfile
from pathlib import Path
from urllib.parse import urlparse

import boto3
import joblib
import numpy as np
import kserve
from botocore.config import Config

LOG = logging.getLogger(__name__)
DEFAULT_CLASS_NAMES = {"0": "setosa", "1": "versicolor", "2": "virginica"}


class IrisClassifier(kserve.Model):
    def __init__(self, name: str = "iris-classifier") -> None:
        super().__init__(name)
        self.model = None
        self.class_names = DEFAULT_CLASS_NAMES.copy()
        self.model_version = os.getenv("MODEL_VERSION", "unknown")
        self.model_uri = os.getenv(
            "MODEL_URI", "s3://mlpipeline/models/iris-classifier/versions/v1/"
        )
        self.load()

    def load(self) -> None:
        """Download the versioned model artifacts from SeaweedFS S3 and load them."""
        parsed = urlparse(self.model_uri)
        if parsed.scheme != "s3" or not parsed.netloc:
            raise ValueError("MODEL_URI must be an S3 URI, e.g. s3://bucket/path/to/version/")

        bucket = parsed.netloc
        prefix = parsed.path.lstrip("/").rstrip("/")
        endpoint = os.getenv("S3_ENDPOINT", "http://seaweedfs.kubeflow.svc.cluster.local:9000")
        if not endpoint.startswith(("http://", "https://")):
            endpoint = f"http://{endpoint}"

        s3 = boto3.client(
            "s3",
            endpoint_url=endpoint,
            region_name=os.getenv("AWS_DEFAULT_REGION", "us-east-1"),
            config=Config(s3={"addressing_style": "path"}),
        )
        with tempfile.TemporaryDirectory(prefix="iris-model-") as tmp:
            model_path = Path(tmp) / "model.joblib"
            manifest_path = Path(tmp) / "manifest.json"
            s3.download_file(bucket, f"{prefix}/model.joblib", str(model_path))
            self.model = joblib.load(model_path)
            try:
                s3.download_file(bucket, f"{prefix}/manifest.json", str(manifest_path))
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                configured_names = manifest.get("class_names")
                if isinstance(configured_names, dict):
                    self.class_names.update({str(k): str(v) for k, v in configured_names.items()})
                if manifest.get("model_version"):
                    self.model_version = str(manifest["model_version"])
                elif manifest.get("version"):
                    self.model_version = str(manifest["version"])
            except Exception as exc:  # manifest is optional for backward compatibility
                LOG.warning("Could not read manifest.json; using default class labels: %s", exc)

        self.ready = True
        LOG.info("Loaded Iris model from %s (version=%s)", self.model_uri, self.model_version)

    def predict(self, payload, headers=None):
        if not self.ready or self.model is None:
            raise RuntimeError("Model is not ready")
        if not isinstance(payload, dict) or not isinstance(payload.get("instances"), list):
            raise ValueError("Expected a V1 request with an 'instances' array")

        instances = payload["instances"]
        if not instances:
            raise ValueError("'instances' must contain at least one feature vector")

        features = np.asarray(instances, dtype=float)
        if features.ndim != 2 or features.shape[1] != 4:
            raise ValueError("Each Iris instance must contain exactly 4 numeric features")
        if not np.isfinite(features).all():
            raise ValueError("Feature values must be finite numbers")

        predicted = self.model.predict(features)
        probabilities = self.model.predict_proba(features) if hasattr(self.model, "predict_proba") else None
        classes = getattr(self.model, "classes_", list(dict.fromkeys(predicted.tolist())))
        results = []
        for i, class_id in enumerate(predicted.tolist()):
            class_key = str(class_id.item() if hasattr(class_id, "item") else class_id)
            probability_map = {}
            confidence = None
            if probabilities is not None:
                probability_map = {
                    self.class_names.get(str(c.item() if hasattr(c, "item") else c), str(c)): round(float(p), 6)
                    for c, p in zip(classes, probabilities[i])
                }
                confidence = round(float(np.max(probabilities[i])), 6)
            results.append({
                "class_id": int(class_id.item() if hasattr(class_id, "item") else class_id),
                "class_name": self.class_names.get(class_key, class_key),
                "confidence": confidence,
                "probabilities": probability_map,
            })
        return {"predictions": results, "model": self.name, "model_version": self.model_version}


if __name__ == "__main__":
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    model = IrisClassifier(os.getenv("MODEL_NAME", "iris-classifier"))
    kserve.ModelServer(http_port=int(os.getenv("PORT", "8080"))).start([model])
