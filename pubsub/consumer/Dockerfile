# Metrics consumer: Kafka -> InfluxDB + MongoDB.
FROM python:3.11-slim

# Pin kafka-python to match the xApp producer (2.0.2); 3.11 base keeps it compatible.
RUN pip install --no-cache-dir "kafka-python==2.0.2" "pymongo>=4.6,<5"

WORKDIR /app
COPY consumer.py /app/consumer.py
COPY sinks.py /app/sinks.py
# Vendored copy of ric/xApps/python/lib/influx_writer.py — keep in sync
# (rebuild this image if that file changes).
COPY influx_writer.py /app/influx_writer.py

CMD ["python", "-u", "consumer.py"]
