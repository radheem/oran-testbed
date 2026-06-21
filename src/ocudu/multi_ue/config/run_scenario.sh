#!/bin/bash
#
# Single entry point for UE test scenarios (see TESTING.md).
# Starts the chosen scenario inside the UE netns and exports throughput +
# latency to InfluxDB via ue_export.py.
#
# Examples:
#   run_scenario.sh --voip-server
#   run_scenario.sh --voip-client --server-ip paris.bbr.iperf.bytel.fr --port 9200
#   run_scenario.sh --file-client --server-ip 10.45.0.1 --duration 30
#   run_scenario.sh --latency --server-ip 8.8.8.8
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UE="${UE_NUM:-1}"
PORT="5201"
DURATION=""
SERVER_IP=""
SCENARIO=""
ROLE=""
PROTO="tcp"
BITRATE=""
LENGTH=""
PARALLEL="1"
EXTRA=()        # passthrough flags to ue_export.py (--no-export, --no-ping, latency)

usage() {
  cat <<'EOF'
Usage: run_scenario.sh <scenario> [options]

Client scenarios (require --server-ip):
  --voip-client        G.711 VoIP   : UDP -b 100k -l 160
  --voip-g729-client   G.729 VoIP   : UDP -b 32k  -l 20
  --video-client       HD video call: UDP -b 5M   -l 1450
  --sd-client          SD streaming : TCP -b 3M
  --4k-client          4K UHD stream: TCP -b 50M
  --iot-client         IoT/sensor   : UDP -b 10k  -l 100
  --file-client        Bulk transfer: TCP -P 4 (unlimited)
  --latency            ICMP RTT only (ping)

Server scenarios:
  --iperf-server       iperf3 -s (TCP/UDP)
  --voip-server        alias for iperf3 -s

Options:
  --server-ip <ip|host>   target (clients/latency)
  --ue <N>                UE number / netns ue<N> (default $UE_NUM or 1)
  --port <p>              port (default 5201)
  --duration <s>          test duration (client 60s, latency 30s)
  --bitrate <v>           override -b (e.g. 2M)
  --length <v>            override -l
  --parallel <n>          override -P
  --no-ping               client: skip the parallel latency ping
  --no-export             do not push metrics to InfluxDB
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --voip-client|--voip-g711-client) SCENARIO=voip;          ROLE=client; PROTO=udp; BITRATE=100k; LENGTH=160 ;;
    --voip-g729-client)               SCENARIO=voip_g729;     ROLE=client; PROTO=udp; BITRATE=32k;  LENGTH=20 ;;
    --video-client)                   SCENARIO=video_hd;      ROLE=client; PROTO=udp; BITRATE=5M;   LENGTH=1450 ;;
    --sd-client)                      SCENARIO=sd_stream;     ROLE=client; PROTO=tcp; BITRATE=3M ;;
    --4k-client)                      SCENARIO=uhd_4k;        ROLE=client; PROTO=tcp; BITRATE=50M ;;
    --iot-client)                     SCENARIO=iot;           ROLE=client; PROTO=udp; BITRATE=10k;  LENGTH=100 ;;
    --file-client)                    SCENARIO=file_transfer; ROLE=client; PROTO=tcp; PARALLEL=4 ;;
    --latency|--ping)                 SCENARIO=latency;       ROLE=client; EXTRA+=("--latency-only") ;;
    --iperf-server|--server)          SCENARIO=server;        ROLE=server; PROTO=tcp ;;
    --voip-server|--udp-server)       SCENARIO=server;        ROLE=server; PROTO=udp ;;
    --server-ip) SERVER_IP="$2"; shift ;;
    --ue)        UE="$2"; shift ;;
    --port)      PORT="$2"; shift ;;
    --duration)  DURATION="$2"; shift ;;
    --bitrate)   BITRATE="$2"; shift ;;
    --length)    LENGTH="$2"; shift ;;
    --parallel)  PARALLEL="$2"; shift ;;
    --no-ping)   EXTRA+=("--no-ping") ;;
    --no-export) EXTRA+=("--no-export") ;;
    --reverse)   EXTRA+=("--reverse") ;;
    --bidir)     EXTRA+=("--bidir") ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if [[ -z "$ROLE" ]]; then
  echo "Error: no scenario selected." >&2; usage; exit 1
fi

NS="ue${UE}"
if ! ip netns list | grep -qw "$NS"; then
  echo "Error: netns $NS not found. Run start_ue.sh ${UE} first." >&2
  exit 1
fi

# Default durations
if [[ -z "$DURATION" ]]; then
  [[ "$SCENARIO" == "latency" ]] && DURATION=30 || DURATION=60
fi

ARGS=(--role "$ROLE" --ue "$UE" --scenario "$SCENARIO" --proto "$PROTO"
      --port "$PORT" --duration "$DURATION" --parallel "$PARALLEL")
[[ -n "$SERVER_IP" ]] && ARGS+=(--server-ip "$SERVER_IP")
[[ -n "$BITRATE"  ]] && ARGS+=(--bitrate "$BITRATE")
[[ -n "$LENGTH"   ]] && ARGS+=(--length "$LENGTH")
[[ ${#EXTRA[@]} -gt 0 ]] && ARGS+=("${EXTRA[@]}")

echo "Scenario: ${SCENARIO} (${ROLE}/${PROTO}) on ${NS} -> ${SERVER_IP:-n/a}:${PORT}"
exec python3 "${HERE}/ue_export.py" "${ARGS[@]}"
