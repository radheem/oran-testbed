#!/usr/bin/env python3
"""
Kafka metrics publisher for xApps.

Drop-in replacement for lib.influx_writer.InfluxWriter: exposes the same
write(fields, tags, timestamp_ns) signature, but instead of POSTing line
protocol to InfluxDB it publishes a JSON message to a Kafka topic. A separate
consumer reads the topic and fans the metric out to InfluxDB + MongoDB.

Best-effort, exactly like InfluxWriter: it never raises into the E2 indication
callback and warns at most once if the broker is unreachable, so a dead broker
can never stall the xApp.

Message schema (JSON):
    {"measurement": str, "tags": {..}, "fields": {..},
     "timestamp_ns": int, "xapp": str}

Config from the environment:
    KAFKA_ENABLE             "1"/"true" to enable (default enabled)
    KAFKA_BOOTSTRAP_SERVERS  comma list, e.g. kafka:9092 (default kafka:9092)
    KAFKA_TOPIC              topic name (default "xapp-metrics")
    XAPP_NAME               source tag (default = measurement)
"""

import json
import os
import time


def _truthy(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


class MetricsPublisher:
    def __init__(self, measurement="kpm", logger=None):
        self.measurement = measurement
        self.logger = logger
        self.enabled = _truthy(os.getenv("KAFKA_ENABLE", "1"))
        self.topic = os.getenv("KAFKA_TOPIC", "xapp-metrics")
        self.xapp = os.getenv("XAPP_NAME", measurement)
        self._warned = False
        self._producer = None

        if not self.enabled:
            return
        bootstrap = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092").split(",")
        try:
            from kafka import KafkaProducer
            self._producer = KafkaProducer(
                bootstrap_servers=bootstrap,
                value_serializer=lambda v: json.dumps(v).encode("utf-8"),
                acks=1,
                retries=2,
                linger_ms=50,
                request_timeout_ms=3000,
                # Bound the time send() can block so a dead broker never hangs
                # the indication callback.
                max_block_ms=2000,
            )
        except Exception as exc:  # noqa: BLE001 - best-effort init
            self._warn("Kafka producer init failed ({}); metrics will not be "
                       "published.".format(exc))

    def _log(self, msg):
        if self.logger:
            self.logger(msg)
        else:
            print(msg)

    def _warn(self, msg):
        if not self._warned:
            self._log("WARN: " + msg)
            self._warned = True

    def write(self, fields, tags=None, timestamp_ns=None):
        """Publish a single point. Same signature as InfluxWriter.write()."""
        if not self.enabled or self._producer is None:
            return
        # Keep only numeric field values, matching InfluxWriter semantics.
        numeric = {}
        for k, v in (fields or {}).items():
            try:
                numeric[k] = float(v)
            except (TypeError, ValueError):
                continue
        if not numeric:
            return

        msg = {
            "measurement": self.measurement,
            "tags": {k: v for k, v in (tags or {}).items() if v is not None},
            "fields": numeric,
            "timestamp_ns": int(timestamp_ns) if timestamp_ns else time.time_ns(),
            "xapp": self.xapp,
        }
        try:
            self._producer.send(self.topic, msg)  # async, fire-and-forget
        except Exception as exc:  # noqa: BLE001 - never raise into callback
            self._warn("Kafka publish failed ({}); metrics will not appear in "
                       "Grafana/Mongo.".format(exc))
