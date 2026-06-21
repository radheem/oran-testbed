#!/usr/bin/env python3
"""
Factory for the xApp metrics sink.

Lets an xApp pick its metrics backend with a single line:

    from lib.metrics_writer import get_metrics_writer
    self.influx = get_metrics_writer(measurement="kpm")
    ...
    self.influx.write(fields, tags=tags)   # signature unchanged

Backend is chosen by METRICS_BACKEND:
    kafka  (default) -> lib.metrics_publisher.MetricsPublisher  (pub/sub)
    influx           -> lib.influx_writer.InfluxWriter          (direct write)

Both backends share the same write(fields, tags, timestamp_ns) contract, so
switching is a config change with no code change. `influx` is the rollback.
"""

import os


def get_metrics_writer(measurement="kpm", logger=None):
    backend = os.getenv("METRICS_BACKEND", "kafka").strip().lower()
    if backend == "influx":
        from lib.influx_writer import InfluxWriter
        return InfluxWriter(measurement=measurement, logger=logger)
    from lib.metrics_publisher import MetricsPublisher
    return MetricsPublisher(measurement=measurement, logger=logger)
