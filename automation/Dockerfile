FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements-automation.txt .
RUN pip install -r requirements-automation.txt

COPY automation/ /app/automation/
COPY pipeline/iris_pipeline.yaml /app/pipeline/iris_pipeline.yaml

RUN useradd --create-home --uid 10001 runner
USER 10001

CMD ["python", "-m", "automation.submit"]