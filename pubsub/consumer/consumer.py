#!/usr/bin/env python3
"""
Metrics consumer: Kafka -> InfluxDB + MongoDB.

Reads JSON metric messages published by the xApps (lib/metrics_publisher.py),
and for each message:
  1) writes a point to InfluxDB 3 (reusing the xApp's InfluxWriter, so the
     line-protocol/bucket behaviour is identical and Grafana keeps working),
  2) inserts the document into MongoDB (one collection per measurement).

Message schema:
  {"measurement": str, "tags": {..}, "fields": {..}, "timestamp_ns": int, "xapp": str}

Resilience: waits for the broker on startup, and never dies on a single bad
message — each is handled in its own try/except.

Env:
  KAFKA_BOOTSTRAP_SERVERS  default kafka:9092
  KAFKA_TOPIC              default xapp-metrics
  KAFKA_GROUP_ID           default metrics-consumer
  INFLUX_URL / INFLUX_BUCKET  read by InfluxWriter (default http://influxdb:8081 / srsran)
  MONGO_URI               default mongodb://metrics_mongo:27017
  MONGO_DB                default metrics
"""

import json
import logging
import os
import time

from kafka import KafkaConsumer
from pymongo import MongoClient

from influx_writer import InfluxWriter  # vendored copy of the xApp writer

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("consumer")

BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
TOPIC = os.getenv("KAFKA_TOPIC", "xapp-metrics")
GROUP = os.getenv("KAFKA_GROUP_ID", "metrics-consumer")
MONGO_URI = os.getenv("MONGO_URI", "mongodb://metrics_mongo:27017")
MONGO_DB = os.getenv("MONGO_DB", "metrics")
# InfluxDB 3: INFLUX_URL / INFLUX_BUCKET read by InfluxWriter from the env.

# InfluxDB 2 (O-RAN AIMLFW-compatible) — second sink, data written as-is.
INFLUX2_ENABLE = os.getenv("INFLUX2_ENABLE", "1").strip().lower() in ("1", "true", "yes", "on")
INFLUX2_URL = os.getenv("INFLUX2_URL", "http://influxdb2:8086")
INFLUX2_BUCKET = os.getenv("INFLUX2_BUCKET", "srsran")
INFLUX2_ORG = os.getenv("INFLUX2_ORG", "primary")
INFLUX2_TOKEN = os.getenv("INFLUX2_TOKEN", "")


def make_consumer():
    while True:
        try:
            c = KafkaConsumer(
                TOPIC,
                bootstrap_servers=BOOTSTRAP.split(","),
                group_id=GROUP,
                enable_auto_commit=True,
                auto_offset_reset="latest",  # testbed: don't replay old history
                value_deserializer=lambda b: json.loads(b.decode("utf-8")),
            )
            log.info("connected to Kafka %s, topic=%s group=%s", BOOTSTRAP, TOPIC, GROUP)
            return c
        except Exception as exc:  # NoBrokersAvailable etc. — version-agnostic
            log.warning("Kafka not reachable at %s (%s); retrying in 3s", BOOTSTRAP, exc)
            time.sleep(3)


def main():
    mongo = MongoClient(MONGO_URI)[MONGO_DB]
    log.info("mongo target: %s/%s", MONGO_URI, MONGO_DB)

    # One InfluxWriter per measurement (measurement is per-message), per target.
    writers = {}       # InfluxDB 3 (env-configured)
    writers2 = {}      # InfluxDB 2 (AIMLFW-compatible)

    def writer_for(meas):
        if meas not in writers:
            writers[meas] = InfluxWriter(measurement=meas)
        return writers[meas]

    def writer2_for(meas):
        if meas not in writers2:
            writers2[meas] = InfluxWriter(measurement=meas, url=INFLUX2_URL,
                                          bucket=INFLUX2_BUCKET, org=INFLUX2_ORG,
                                          token=INFLUX2_TOKEN)
        return writers2[meas]

    if INFLUX2_ENABLE:
        log.info("influxdb2 sink: %s org=%s bucket=%s", INFLUX2_URL, INFLUX2_ORG, INFLUX2_BUCKET)

    consumer = make_consumer()
    n = 0
    for msg in consumer:
        try:
            m = msg.value
            meas = m.get("measurement", "kpm")
            fields = m.get("fields", {}) or {}
            tags = m.get("tags", {}) or {}
            ts_ns = m.get("timestamp_ns")

            # 1) InfluxDB 3 (never raises; warn-once on failure).
            writer_for(meas).write(fields, tags=tags, timestamp_ns=ts_ns)

            # 1b) InfluxDB 2 (AIMLFW-compatible), same point, data as-is.
            if INFLUX2_ENABLE:
                writer2_for(meas).write(fields, tags=tags, timestamp_ns=ts_ns)

            # 2) MongoDB: collection per measurement + ingest timestamp.
            doc = dict(m)
            doc["ingested_at_ns"] = time.time_ns()
            mongo[meas].insert_one(doc)

            n += 1
            if n % 20 == 1:
                log.info("processed %d messages (last measurement=%s, xapp=%s)",
                         n, meas, m.get("xapp"))
        except Exception as exc:  # noqa: BLE001 - never die on one message
            log.warning("skipping message: %s", exc)


if __name__ == "__main__":
    main()
