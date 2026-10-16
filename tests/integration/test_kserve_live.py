
import os

import pytest
import requests


KSERVE_URL = os.getenv(
    "KSERVE_URL",
    "http://localhost:8082/v1/models/iris-classifier:predict",
)

EXPECTED_CLASSES = {"setosa", "versicolor", "virginica"}
EXPECTED_MODEL_NAME = "iris-classifier"
EXPECTED_MODEL_VERSION = "v1"


@pytest.mark.integration
def test_live_predictor_returns_valid_predictions() -> None:
    response = requests.post(
        KSERVE_URL,
        json={
            "instances": [
                [5.1, 3.5, 1.4, 0.2],
                [6.7, 3.0, 5.2, 2.3],
            ]
        },
        timeout=15,
    )

    response.raise_for_status()
    body = response.json()

    assert body["model"] == EXPECTED_MODEL_NAME
    assert body["model_version"] == EXPECTED_MODEL_VERSION

    predictions = body["predictions"]
    assert len(predictions) == 2

    for prediction in predictions:
        assert prediction["class_id"] in {0, 1, 2}
        assert prediction["class_name"] in EXPECTED_CLASSES

        probabilities = prediction["probabilities"]

        assert set(probabilities) == EXPECTED_CLASSES

        for class_name, probability in probabilities.items():
            assert isinstance(probability, (int, float)), class_name
            assert 0.0 <= probability <= 1.0

        assert sum(probabilities.values()) == pytest.approx(
            1.0,
            abs=1e-3,
        )

        confidence = prediction["confidence"]

        assert 0.0 <= confidence <= 1.0
        assert confidence == pytest.approx(
            max(probabilities.values()),
            abs=1e-3,
        )
