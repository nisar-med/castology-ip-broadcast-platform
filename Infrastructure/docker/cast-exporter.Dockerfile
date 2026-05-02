FROM python:3.12-slim

RUN pip install --no-cache-dir prometheus_client requests

WORKDIR /app
COPY scripts/cast-prom-metrics.py cast-prom-metrics.py

CMD ["python3", "cast-prom-metrics.py"]
