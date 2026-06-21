#!/usr/bin/env python3
"""
Generic metrics consumer: Kafka -> one pluggable sink.

The same image runs as N independent consumers; each container picks a sink
(SINK env) and its own Kafka subscription, so a new purpose is one more
container, not a code change. Different KAFKA_GROUP_ID per container means each
consumer group receives every message independently.

Subscription env:
    KAFKA_BOOTSTRAP_SERVERS   default kafka:9092
    KAFKA_TOPIC               default xapp-metrics
    KAFKA_GROUP_ID            default metrics-consumer   (use a distinct id per sink)
    KAFKA_OFFSET_RESET        default latest             (earliest = replay history)

Sink env: see sinks.py (SINK=influx|mongo and the per-sink DB params).
"""

import json
import logging
import os
import time

from kafka import KafkaConsumer

from sinks import build_sink

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("consumer")

BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
TOPIC = os.getenv("KAFKA_TOPIC", "xapp-metrics")
GROUP = os.getenv("KAFKA_GROUP_ID", "metrics-consumer")
OFFSET = os.getenv("KAFKA_OFFSET_RESET", "latest")


def make_consumer():
    while True:
        try:
            c = KafkaConsumer(
                TOPIC,
                bootstrap_servers=BOOTSTRAP.split(","),
                group_id=GROUP,
                enable_auto_commit=True,
                auto_offset_reset=OFFSET,
                value_deserializer=lambda b: json.loads(b.decode("utf-8")),
            )
            log.info("connected to Kafka %s topic=%s group=%s offset=%s",
                     BOOTSTRAP, TOPIC, GROUP, OFFSET)
            return c
        except Exception as exc:  # NoBrokersAvailable etc. — version-agnostic
            log.warning("Kafka not reachable at %s (%s); retrying in 3s", BOOTSTRAP, exc)
            time.sleep(3)


def main():
    sink = build_sink()
    log.info("starting consumer: sink=%s group=%s topic=%s", sink.name, GROUP, TOPIC)
    consumer = make_consumer()
    n = 0
    for msg in consumer:
        try:
            sink.write(msg.value)
            n += 1
            if n % 50 == 1:
                log.info("[%s] processed %d messages (last xapp=%s)",
                         sink.name, n, (msg.value or {}).get("xapp"))
        except Exception as exc:  # noqa: BLE001 - never die on one message
            log.warning("[%s] skipping message: %s", sink.name, exc)


if __name__ == "__main__":
    main()
