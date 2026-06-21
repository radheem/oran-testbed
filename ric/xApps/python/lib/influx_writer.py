#!/usr/bin/env python3
"""
Best-effort InfluxDB 3 writer for xApps.

Pushes line-protocol points to the same InfluxDB 3 instance that Grafana reads
(the srsRAN docker 'metrics' stack). Uses only the Python stdlib so it adds no
dependency to the xApp container, and never raises into the caller: if InfluxDB
is unreachable the xApp keeps running and a single warning is logged.

Config is read from the environment (defaults match srsRAN_Project/docker/.env):
    INFLUX_ENABLE   "1"/"true" to enable (default enabled)
    INFLUX_URL      base URL, e.g. http://influxdb:8081
    INFLUX_BUCKET   database/bucket name (default "srsran")
    INFLUX_ORG      org (optional; InfluxDB 3 core ignores it)
    INFLUX_TOKEN    auth token (optional; stack runs --without-auth)
"""

import os
import time
import urllib.error
import urllib.parse
import urllib.request


def _truthy(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def _escape_tag(value):
    # Line-protocol tag keys/values escape commas, equals and spaces.
    return (
        str(value)
        .replace("\\", "\\\\")
        .replace(",", "\\,")
        .replace("=", "\\=")
        .replace(" ", "\\ ")
    )


def _escape_field_key(key):
    # Dots are legal in line protocol but awkward to query in SQL, so map
    # DRB.UEThpDl -> DRB_UEThpDl. Also escape the usual separators.
    key = str(key).replace(".", "_")
    return key.replace(",", "\\,").replace("=", "\\=").replace(" ", "\\ ")


class InfluxWriter:
    def __init__(self, measurement="kpm", logger=None,
                 url=None, bucket=None, org=None, token=None, enable=None):
        # Explicit args win over env (env defaults preserve old behaviour). This
        # lets one process target several InfluxDB instances (e.g. v3 and v2).
        self.measurement = measurement
        self.logger = logger
        self.enabled = enable if enable is not None else _truthy(os.getenv("INFLUX_ENABLE", "1"))

        base = (url if url is not None else os.getenv("INFLUX_URL", "http://influxdb:8081")).rstrip("/")
        bucket = bucket if bucket is not None else os.getenv("INFLUX_BUCKET", "srsran")
        org = org if org is not None else os.getenv("INFLUX_ORG", "")
        self.token = token if token is not None else os.getenv("INFLUX_TOKEN", "")

        params = {"bucket": bucket, "precision": "ns"}
        if org:
            params["org"] = org
        # v2-compatible write endpoint; supported by InfluxDB 3 core.
        self.url = base + "/api/v2/write?" + urllib.parse.urlencode(params)
        self._warned = False

    def _log(self, msg):
        if self.logger:
            self.logger(msg)
        else:
            print(msg)

    def write(self, fields, tags=None, timestamp_ns=None):
        """Write a single point. fields: {name: float}; tags: {name: str}."""
        if not self.enabled:
            return
        numeric = {}
        for k, v in fields.items():
            try:
                numeric[k] = float(v)
            except (TypeError, ValueError):
                continue
        if not numeric:
            return

        line = self.measurement
        for tk, tv in (tags or {}).items():
            if tv is None:
                continue
            line += ",{}={}".format(_escape_tag(tk), _escape_tag(tv))
        line += " " + ",".join(
            "{}={}".format(_escape_field_key(k), v) for k, v in numeric.items()
        )
        if timestamp_ns is None:
            timestamp_ns = time.time_ns()
        line += " {}".format(int(timestamp_ns))

        self._post(line.encode("utf-8"))

    def _post(self, body):
        req = urllib.request.Request(self.url, data=body, method="POST")
        req.add_header("Content-Type", "text/plain; charset=utf-8")
        if self.token:
            req.add_header("Authorization", "Token {}".format(self.token))
        try:
            urllib.request.urlopen(req, timeout=2).read()
        except (urllib.error.URLError, OSError) as exc:
            # Warn once, then stay quiet so we don't spam every indication.
            if not self._warned:
                self._log("WARN: InfluxDB write failed ({}); "
                          "metrics will not appear in Grafana.".format(exc))
                self._warned = True
