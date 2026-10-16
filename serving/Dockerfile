
FROM python:3.11-slim

WORKDIR /app

# Build native Python extensions when a compatible wheel is unavailable.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY serving/requirements.txt ./requirements.txt

RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

COPY serving/model.py ./model.py

EXPOSE 8080

CMD ["python", "model.py"]
