#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# SPDX-License-Identifier: GPL-3.0
#
# Co-located ZMQ bridge for N srsUE instances sharing ONE container IP.
#
# Model (migrated from the k8s srsue deployment): every UE and this bridge bind
# their ZMQ sockets to the SAME host IP and are differentiated only by PORT.
# That removes the need for a per-UE IP / IP aliasing on the container.
#
#   gNB side (single pair):
#     gNB tx  tcp://GNB_IP:2000  -> bridge req_source (downlink samples)
#     bridge rep_sink tcp://HOST_IP:2001 -> gNB rx      (uplink aggregate)
#
#   Per UE n (1-indexed, matches generate_ue_conf.py):
#     UE tx   tcp://HOST_IP:2100+n -> bridge req_source (that UE's uplink)
#     bridge rep_sink tcp://HOST_IP:2200+n -> UE rx       (that UE's downlink)
#
# The bridge sums all UE uplinks into the single gNB uplink, and fans the single
# gNB downlink out to every UE. Port numbering is identical to the standalone
# ue/bridge/zmq_bridge.py so the gNB device_args stay unchanged.

from argparse import ArgumentParser
import signal
import sys

from gnuradio import blocks
from gnuradio import gr
from gnuradio import zeromq


class MultiUeBridge(gr.top_block):
    def __init__(self, ue_ids, gnb_ip, host_ip, gnb_tx_port=2000, gnb_rx_port=2001):
        super().__init__("srsRAN_multi_UE")

        zmq_timeout = 100
        zmq_hwm = -1
        samp_rate = 23040000

        # gNB side (single pair). req_source connects to the gNB tx; rep_sink
        # binds on the host IP for the gNB to connect its rx to. Ports are
        # parameterized so a second bridge can serve a second cell/gNB.
        self.gnb_dl_source = zeromq.req_source(
            gr.sizeof_gr_complex, 1, f"tcp://{gnb_ip}:{gnb_tx_port}", zmq_timeout, False, zmq_hwm)
        self.gnb_ul_sink = zeromq.rep_sink(
            gr.sizeof_gr_complex, 1, f"tcp://{host_ip}:{gnb_rx_port}", zmq_timeout, False, zmq_hwm)

        # Aggregate uplink from all UEs; throttle drives the downlink fan-out.
        self.ul_add = blocks.add_vcc(1)
        self.throttle = blocks.throttle(gr.sizeof_gr_complex * 1, samp_rate, True)

        self.connect((self.gnb_dl_source, 0), (self.throttle, 0))
        self.connect((self.ul_add, 0), (self.gnb_ul_sink, 0))

        # Per-UE sockets, all on the same host IP, differentiated by port.
        self.ue_ul_sources = []
        self.ue_dl_sinks = []
        for input_idx, n in enumerate(ue_ids):
            ul_port = 2100 + n
            dl_port = 2200 + n

            ue_ul = zeromq.req_source(
                gr.sizeof_gr_complex, 1, f"tcp://{host_ip}:{ul_port}", zmq_timeout, False, zmq_hwm)
            ue_dl = zeromq.rep_sink(
                gr.sizeof_gr_complex, 1, f"tcp://{host_ip}:{dl_port}", zmq_timeout, False, zmq_hwm)

            self.ue_ul_sources.append(ue_ul)
            self.ue_dl_sinks.append(ue_dl)

            self.connect((ue_ul, 0), (self.ul_add, input_idx))
            self.connect((self.throttle, 0), (ue_dl, 0))


def main():
    parser = ArgumentParser(description="Co-located ZMQ bridge for multiple srsUEs on one host IP")
    parser.add_argument("-n", "--num-ues", type=int, default=2,
                        help="Number of UEs (activates UE ids 1..N)")
    parser.add_argument("--ue-ids", default="",
                        help="Comma-separated UE ids to activate (overrides --num-ues, e.g. 1,2,3)")
    parser.add_argument("--gnb-ip", default="10.10.3.231", help="gNB N3 IP (ZMQ tx)")
    parser.add_argument("--host-ip", default="10.10.4.237",
                        help="This container's ue_n3 IP; all UE + gNB-rx sockets bind here")
    parser.add_argument("--gnb-tx-port", type=int, default=2000, help="gNB ZMQ tx port")
    parser.add_argument("--gnb-rx-port", type=int, default=2001, help="gNB ZMQ rx port")
    args = parser.parse_args()

    if args.ue_ids.strip():
        ue_ids = [int(x) for x in args.ue_ids.split(",") if x.strip()]
    else:
        ue_ids = list(range(1, args.num_ues + 1))
    if not ue_ids:
        raise ValueError("No UE ids to activate")

    tb = MultiUeBridge(ue_ids, args.gnb_ip, args.host_ip,
                       gnb_tx_port=args.gnb_tx_port, gnb_rx_port=args.gnb_rx_port)

    def sig_handler(sig=None, frame=None):
        tb.stop()
        tb.wait()
        sys.exit(0)

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    print(f"Bridge up: gNB={args.gnb_ip}:{args.gnb_tx_port}/{args.gnb_rx_port} "
          f"host={args.host_ip} ues={ue_ids}", file=sys.stderr)
    tb.start()
    signal.pause()


if __name__ == "__main__":
    main()
