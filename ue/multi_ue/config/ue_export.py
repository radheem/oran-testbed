#!/usr/bin/env python3
"""
UE traffic + latency runner with InfluxDB export.

Runs iperf3 and ping *inside* a UE network namespace, parses iperf 3.7 text
output live (no --json-stream in 3.7), and pushes metrics to the same InfluxDB 3
that Grafana reads. Stdlib only; best-effort writes never crash the run.

Measurements:
  ue_traffic  tags: ue_id, scenario, proto, role, server
              fields: throughput_mbps, retransmits, jitter_ms, loss_pct
  ue_latency  tags: ue_id, target
              fields: rtt_ms, rtt_min_ms, rtt_avg_ms, rtt_max_ms, rtt_mdev_ms
"""

import argparse
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


# ----------------------------- InfluxDB writer -----------------------------
def _esc_tag(v):
    return (str(v).replace("\\", "\\\\").replace(",", "\\,")
            .replace("=", "\\=").replace(" ", "\\ "))


class Influx:
    def __init__(self, enabled, url, bucket, org, token):
        self.enabled = enabled
        self.token = token or ""
        params = {"bucket": bucket, "precision": "ns"}
        if org:
            params["org"] = org
        self.url = url.rstrip("/") + "/api/v2/write?" + urllib.parse.urlencode(params)
        self._warned = False

    def write(self, measurement, tags, fields, ts_ns=None):
        if not self.enabled:
            return
        num = {}
        for k, v in fields.items():
            try:
                num[k] = float(v)
            except (TypeError, ValueError):
                continue
        if not num:
            return
        line = measurement
        for tk, tv in tags.items():
            if tv is None or tv == "":
                continue
            line += ",{}={}".format(_esc_tag(tk), _esc_tag(tv))
        line += " " + ",".join("{}={}".format(k, v) for k, v in num.items())
        line += " {}".format(int(ts_ns if ts_ns is not None else time.time_ns()))
        try:
            req = urllib.request.Request(self.url, data=line.encode(), method="POST")
            req.add_header("Content-Type", "text/plain; charset=utf-8")
            if self.token:
                req.add_header("Authorization", "Token {}".format(self.token))
            urllib.request.urlopen(req, timeout=2).read()
        except (urllib.error.URLError, OSError) as exc:
            if not self._warned:
                print("WARN: InfluxDB write failed ({}); metrics not exported."
                      .format(exc), file=sys.stderr)
                self._warned = True


# ----------------------------- parsing helpers -----------------------------
_UNIT = {"K": 1e-3, "M": 1.0, "G": 1e3, "k": 1e-3, "m": 1.0, "g": 1e3}
# [ ID] 0.00-1.00 sec <transfer> <U>Bytes <rate> <U>bits/sec <tail>
_LINE = re.compile(r"\[\s*(\S+)\]\s+([\d.]+)-([\d.]+)\s+sec\s+.*?"
                   r"([\d.]+)\s+([KMGkmg])bits/sec(.*)$")
_JITTER = re.compile(r"([\d.]+)\s+ms\s+(\d+)/(\d+)\s+\(([\d.]+|-?nan)%\)")
_TCP_RETR = re.compile(r"bits/sec\s+(\d+)\s+sender")
_PING_RTT = re.compile(r"time=([\d.]+)\s*ms")
_PING_SUMMARY = re.compile(r"=\s*([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)\s*ms")


def netns_cmd(ns, argv):
    return ["ip", "netns", "exec", ns] + argv


# ----------------------------- iperf handling ------------------------------
def run_iperf(proc_argv, ns, influx, base_tags, parallel):
    """Spawn iperf3 in the netns; parse output line-by-line; push live."""
    cmd = netns_cmd(ns, proc_argv)
    print("+ " + " ".join(cmd), file=sys.stderr)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1)
    use_sum = parallel > 1
    for line in iter(proc.stdout.readline, ""):
        line = line.rstrip("\n")
        m = _LINE.search(line)
        if not m:
            continue
        sid, start, end, rate, unit, tail = m.groups()
        # With -P>1 prefer the [SUM] rows; otherwise the single numeric stream.
        if use_sum and sid != "SUM":
            continue
        if not use_sum and sid == "SUM":
            continue
        mbps = float(rate) * _UNIT[unit]
        is_summary = ("sender" in tail) or ("receiver" in tail)
        ts = time.time_ns()
        if is_summary:
            fields = {"throughput_mbps": mbps}
            jm = _JITTER.search(tail)
            if jm:
                fields["jitter_ms"] = jm.group(1)
                fields["loss_pct"] = (0.0 if "nan" in jm.group(4) else jm.group(4))
            rm = _TCP_RETR.search(line)
            if rm:
                fields["retransmits"] = rm.group(1)
            influx.write("ue_traffic", dict(base_tags, kind="summary"), fields, ts)
            print("  [summary] {:.3f} Mbps {}".format(mbps, tail.strip()),
                  file=sys.stderr)
        else:
            influx.write("ue_traffic", base_tags, {"throughput_mbps": mbps}, ts)
            print("  {:>6}-{:<6}s  {:.3f} Mbps".format(start, end, mbps),
                  file=sys.stderr)
    proc.stdout.close()
    return proc.wait()


# ----------------------------- ping handling -------------------------------
def run_ping(ns, target, influx, ue_id, stop_evt):
    cmd = netns_cmd(ns, ["ping", "-i", "1", "-W", "1", target])
    print("+ " + " ".join(cmd), file=sys.stderr)
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, bufsize=1)
    except OSError as exc:
        print("WARN: ping failed to start ({})".format(exc), file=sys.stderr)
        return
    tags = {"ue_id": ue_id, "target": target}
    for line in iter(proc.stdout.readline, ""):
        if stop_evt.is_set():
            break
        m = _PING_RTT.search(line)
        if m:
            influx.write("ue_latency", tags, {"rtt_ms": m.group(1)})
            continue
        s = _PING_SUMMARY.search(line)
        if s:
            influx.write("ue_latency", tags, {
                "rtt_min_ms": s.group(1), "rtt_avg_ms": s.group(2),
                "rtt_max_ms": s.group(3), "rtt_mdev_ms": s.group(4)})
    try:
        proc.terminate()
    except OSError:
        pass


# ----------------------------- main ----------------------------------------
def main():
    p = argparse.ArgumentParser(description="UE traffic/latency runner + InfluxDB export")
    p.add_argument("--role", required=True, choices=["client", "server"])
    p.add_argument("--ue", default=os.environ.get("UE_NUM", "1"))
    p.add_argument("--scenario", default="custom")
    p.add_argument("--proto", default="tcp", choices=["tcp", "udp"])
    p.add_argument("--server-ip", default=None)
    p.add_argument("--port", default="5201")
    p.add_argument("--duration", default="60")
    p.add_argument("--bitrate", default=None, help="iperf3 -b value, e.g. 100k, 5M")
    p.add_argument("--length", default=None, help="iperf3 -l payload size")
    p.add_argument("--parallel", type=int, default=1, help="iperf3 -P streams")
    p.add_argument("--reverse", action="store_true",
                   help="iperf3 -R: server->client (downlink from UE perspective)")
    p.add_argument("--bidir", action="store_true",
                   help="iperf3 --bidir: simultaneous uplink + downlink")
    p.add_argument("--no-ping", action="store_true")
    p.add_argument("--latency-only", action="store_true",
                   help="ping only for --duration, no iperf traffic")
    p.add_argument("--no-export", action="store_true")
    # Influx connection (defaults match the srsRAN docker .env)
    p.add_argument("--influx-url", default=os.environ.get("INFLUX_URL", "http://influxdb:8081"))
    p.add_argument("--influx-bucket", default=os.environ.get("INFLUX_BUCKET", "srsran"))
    p.add_argument("--influx-org", default=os.environ.get("INFLUX_ORG", ""))
    p.add_argument("--influx-token", default=os.environ.get("INFLUX_TOKEN", ""))
    args = p.parse_args()

    ns = "ue{}".format(args.ue)
    influx = Influx(not args.no_export, args.influx_url, args.influx_bucket,
                    args.influx_org, args.influx_token)
    base_tags = {"ue_id": args.ue, "scenario": args.scenario,
                 "proto": args.proto, "role": args.role,
                 "server": args.server_ip or ""}

    if args.role == "server":
        argv = ["iperf3", "-s", "-p", str(args.port), "-i", "1", "--forceflush"]
        print("Starting iperf3 server in {} (Ctrl+C to stop)".format(ns), file=sys.stderr)
        return run_iperf(argv, ns, influx, base_tags, parallel=1)

    # client
    if not args.server_ip:
        p.error("--server-ip is required for client role")

    # latency-only: just ping for the duration, no iperf traffic.
    if args.latency_only:
        stop_evt = threading.Event()
        signal.signal(signal.SIGINT, lambda *_: stop_evt.set())
        signal.signal(signal.SIGTERM, lambda *_: stop_evt.set())
        t = threading.Thread(target=run_ping,
                             args=(ns, args.server_ip, influx, args.ue, stop_evt),
                             daemon=True)
        t.start()
        try:
            t.join(timeout=float(args.duration))
        finally:
            stop_evt.set()
        return 0

    argv = ["iperf3", "-c", args.server_ip, "-p", str(args.port),
            "-t", str(args.duration), "-i", "1", "--forceflush"]
    if args.proto == "udp":
        argv.append("-u")
    if args.bitrate:
        argv += ["-b", args.bitrate]
    if args.length:
        argv += ["-l", args.length]
    if args.parallel > 1:
        argv += ["-P", str(args.parallel)]
    if args.bidir:
        argv.append("--bidir")
    elif args.reverse:
        argv.append("-R")

    stop_evt = threading.Event()
    ping_thread = None
    if not args.no_ping:
        ping_thread = threading.Thread(
            target=run_ping, args=(ns, args.server_ip, influx, args.ue, stop_evt),
            daemon=True)
        ping_thread.start()

    def handle_sig(*_):
        stop_evt.set()
    signal.signal(signal.SIGINT, handle_sig)
    signal.signal(signal.SIGTERM, handle_sig)

    rc = run_iperf(argv, ns, influx, base_tags, args.parallel)
    stop_evt.set()
    if ping_thread:
        ping_thread.join(timeout=2)
    return rc


if __name__ == "__main__":
    sys.exit(main() or 0)
