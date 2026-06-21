#!/usr/bin/env python3
"""
Output sinks for the metrics consumer.

Each sink takes a decoded metric message and persists it to one datastore. A sink
is selected per-container by the SINK env var, so the same image runs as N
independent consumers (one per sink), each with its own DB params:

    SINK=influx   -> InfluxSink   (InfluxDB v2 or v3, by URL/bucket/org/token)
    SINK=mongo    -> MongoSink    (MongoDB, document per measurement)

Add a new sink by writing a class with .write(message) and registering it in
SINKS — no change to the consumer loop.

Message schema:
    {"measurement": str, "tags": {..}, "fields": {..}, "timestamp_ns": int, "xapp": str}
"""

import logging
import os
import time
from datetime import datetime, timezone

log = logging.getLogger("consumer")


class InfluxSink:
    """Write a metric as a line-protocol point to InfluxDB (v2 or v3).

    Reuses InfluxWriter; the v2/v3 difference is purely the connection params
    (v2 needs org + token). One writer is cached per measurement.

    Env: INFLUX_URL, INFLUX_BUCKET, INFLUX_ORG, INFLUX_TOKEN.
    """

    name = "influx"

    def __init__(self):
        from influx_writer import InfluxWriter
        self._InfluxWriter = InfluxWriter
        self.url = os.getenv("INFLUX_URL", "http://influxdb:8081")
        self.bucket = os.getenv("INFLUX_BUCKET", "srsran")
        self.org = os.getenv("INFLUX_ORG", "")
        self.token = os.getenv("INFLUX_TOKEN", "")
        self._writers = {}
        log.info("influx sink -> %s bucket=%s org=%s", self.url, self.bucket, self.org or "-")

    def _writer(self, meas):
        if meas not in self._writers:
            self._writers[meas] = self._InfluxWriter(
                measurement=meas, url=self.url, bucket=self.bucket,
                org=self.org, token=self.token, enable=True)
        return self._writers[meas]

    def write(self, m):
        meas = m.get("measurement", "kpm")
        self._writer(meas).write(
            m.get("fields", {}) or {},
            tags=m.get("tags", {}) or {},
            timestamp_ns=m.get("timestamp_ns"))


class MongoSink:
    """Insert a metric as a document (collection per measurement).

    Adds ingested_at_ns and createdon (the xApp created-at = message
    timestamp_ns as a UTC ISO string, falling back to now(UTC)).

    Env: MONGO_URI, MONGO_DB, MONGO_TIMEOUT_MS (fail fast if Mongo is absent).
    """

    name = "mongo"

    def __init__(self):
        from pymongo import MongoClient
        uri = os.getenv("MONGO_URI", "mongodb://metrics_mongo:27017")
        dbname = os.getenv("MONGO_DB", "metrics")
        timeout = int(os.getenv("MONGO_TIMEOUT_MS", "2000"))
        self.db = MongoClient(uri, serverSelectionTimeoutMS=timeout)[dbname]
        log.info("mongo sink -> %s/%s", uri, dbname)

    def write(self, m):
        meas = m.get("measurement", "kpm")
        doc = dict(m)
        doc["ingested_at_ns"] = time.time_ns()
        ts_ns = m.get("timestamp_ns")
        doc["createdon"] = (
            datetime.fromtimestamp(int(ts_ns) / 1e9, tz=timezone.utc).isoformat()
            if ts_ns else datetime.now(timezone.utc).isoformat())
        self.db[meas].insert_one(doc)


SINKS = {InfluxSink.name: InfluxSink, MongoSink.name: MongoSink}


def build_sink():
    """Instantiate the sink named by the SINK env var."""
    kind = os.getenv("SINK", "").strip().lower()
    if kind not in SINKS:
        raise SystemExit("SINK must be one of %s (got %r)" % (sorted(SINKS), kind))
    return SINKS[kind]()
