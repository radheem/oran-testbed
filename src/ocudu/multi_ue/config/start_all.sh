#!/bin/bash
#
# Bring up the co-located ZMQ bridge + N srsUE instances inside ONE container,
# then supervise them. All UEs share this container's IP and are multiplexed by
# ZMQ port (see multi_ue_scenario.py). Each srsUE lands its tun_srsue in its own
# netns ue<n>.
#
# Supervision policy:
#   - The BRIDGE is critical (it carries every UE's RF). If it dies, this script
#     exits non-zero so the container stops and can be recreated cleanly.
#   - A UE is independent. If a srsUE exits (e.g. radio-link failure under heavy
#     load), it is logged and restarted up to MAX_UE_RESTARTS times; one UE
#     failing never tears the whole container down.
#
# Usage: start_all.sh [N]      (N defaults to $NUM_UES, else 2)
#
# Two-cell slicing: UEs in CELL2_UES are served by a second bridge wired to a
# second gNB (cell 2); the rest go to cell 1. With CELL2_UES empty (or no UEs
# in range) only the cell-1 bridge runs (single-cell, backward compatible).
#
# Env knobs:
#   NUM_UES, GNB_IP, UE_HOST_IP, UE_BIND_IP, ZMQ_BRIDGE_IP
#   CELL2_UES           comma list of UE ids on cell 2       (default "3,4")
#   GNB2_IP             cell-2 gNB N3 IP                      (default 10.10.3.232)
#   GNB2_TX_PORT/RX     cell-2 gNB ZMQ ports                 (default 2010/2011)
#   START_STAGGER       seconds between UE starts            (default 3)
#   SUPERVISE_INTERVAL  seconds between health checks        (default 5)
#   RESTART_UES         restart a UE that exits (true|false) (default true)
#   MAX_UE_RESTARTS     per-UE restart cap                   (default 3)
#   LOG_DIR             where bridge*.log / ue<n>.log go     (default /tmp)
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

N="${1:-${NUM_UES:-2}}"
GNB_IP="${GNB_IP:-10.10.3.231}"
UE_HOST_IP="${UE_HOST_IP:-10.10.4.237}"
CELL2_UES="${CELL2_UES:-3,4}"
GNB2_IP="${GNB2_IP:-10.10.3.232}"
GNB2_TX_PORT="${GNB2_TX_PORT:-2010}"
GNB2_RX_PORT="${GNB2_RX_PORT:-2011}"
START_STAGGER="${START_STAGGER:-3}"
# NOTE: do NOT attach UEs sequentially (waiting for each before the next). The
# bridge sums every UE's uplink, so its add block only produces once ALL UE ZMQ
# sources have a peer — i.e. every srsUE must be running. A long gap between UE
# starts stalls the summed uplink and nobody attaches. Keep the stagger short.
SUPERVISE_INTERVAL="${SUPERVISE_INTERVAL:-5}"
RESTART_UES="${RESTART_UES:-true}"
MAX_UE_RESTARTS="${MAX_UE_RESTARTS:-3}"
LOG_DIR="${LOG_DIR:-/tmp}"

# srsUE + bridge both bind ZMQ to the container IP, so point the per-UE config
# generator at the host IP for both the bind and bridge endpoints.
export GNB_IP UE_ZMQ_MODE="bridge"
export UE_BIND_IP="${UE_BIND_IP:-$UE_HOST_IP}"
export ZMQ_BRIDGE_IP="${ZMQ_BRIDGE_IP:-$UE_HOST_IP}"

# Ensure the TUN device node exists (srsUE creates tun_srsue from it).
mkdir -p /dev/net
[ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200

declare -A BRIDGE_PID    # label -> pid  (every bridge is critical)
declare -A UE_PID        # n -> pid of its start_ue.sh subshell
declare -A UE_RESTARTS   # n -> restart count

cleanup() {
  trap - EXIT INT TERM
  echo "Stopping bridges + UEs..."
  if [ "${#BRIDGE_PID[@]}" -gt 0 ]; then
    for pid in "${BRIDGE_PID[@]}"; do kill "${pid}" 2>/dev/null || true; done
  fi
  if [ "${#UE_PID[@]}" -gt 0 ]; then
    for pid in "${UE_PID[@]}"; do kill "${pid}" 2>/dev/null || true; done
  fi
}
trap cleanup EXIT INT TERM

start_one_ue() {
  local n="$1"
  UE_NUM="${n}" "${HERE}/start_ue.sh" "${n}" >"${LOG_DIR}/ue${n}.log" 2>&1 &
  UE_PID[$n]=$!
}

start_bridge() {
  # start_bridge <label> <gnb-ip> <tx-port> <rx-port> <ue-ids-csv>
  local label="$1" gip="$2" txp="$3" rxp="$4" ids="$5"
  echo "=== Starting bridge ${label}: gNB=${gip}:${txp}/${rxp} ues=${ids} ==="
  python3 "${HERE}/multi_ue_scenario.py" --ue-ids "${ids}" \
    --gnb-ip "${gip}" --host-ip "${UE_HOST_IP}" \
    --gnb-tx-port "${txp}" --gnb-rx-port "${rxp}" \
    >"${LOG_DIR}/bridge_${label}.log" 2>&1 &
  BRIDGE_PID[$label]=$!
}

# Partition UE ids 1..N into cell 2 (CELL2_UES) and cell 1 (the rest).
cell2_ids=""; cell1_ids=""
for n in $(seq 1 "${N}"); do
  if [[ ",${CELL2_UES}," == *",${n},"* ]]; then
    cell2_ids="${cell2_ids:+${cell2_ids},}${n}"
  else
    cell1_ids="${cell1_ids:+${cell1_ids},}${n}"
  fi
done

[ -n "${cell1_ids}" ] && start_bridge cell1 "${GNB_IP}"  2000 2001 "${cell1_ids}"
[ -n "${cell2_ids}" ] && start_bridge cell2 "${GNB2_IP}" "${GNB2_TX_PORT}" "${GNB2_RX_PORT}" "${cell2_ids}"

# Give the bridges a moment to bind their sockets before UEs connect.
sleep 2

for n in $(seq 1 "${N}"); do
  echo "=== Starting UE ${n} (netns ue${n}) ==="
  start_one_ue "${n}"
  sleep "${START_STAGGER}"
done

echo "=== All started. Supervising (interval ${SUPERVISE_INTERVAL}s). Logs: ${LOG_DIR}/bridge_*.log, ue<n>.log. ==="
echo "    Check attach:  ip netns exec ue1 ip addr show tun_srsue"
echo "    Generate load: ${HERE}/run_all_scenarios.sh --voip-client --server-ip 10.45.0.1"

# ── Supervisor loop ──────────────────────────────────────────────────────────
while true; do
  sleep "${SUPERVISE_INTERVAL}"

  # Every bridge is critical: its death takes down its cell's RF path.
  for label in "${!BRIDGE_PID[@]}"; do
    if ! kill -0 "${BRIDGE_PID[$label]}" 2>/dev/null; then
      echo "FATAL: bridge ${label} (pid ${BRIDGE_PID[$label]}) exited; tearing down container." >&2
      exit 1
    fi
  done

  # UEs are independent: log, and restart up to the cap.
  for n in "${!UE_PID[@]}"; do
    pid="${UE_PID[$n]}"
    if kill -0 "${pid}" 2>/dev/null; then continue; fi
    wait "${pid}" 2>/dev/null || true
    echo "WARN: UE ${n} (pid ${pid}) exited." >&2
    if [ "${RESTART_UES}" = "true" ] && [ "${UE_RESTARTS[$n]:-0}" -lt "${MAX_UE_RESTARTS}" ]; then
      UE_RESTARTS[$n]=$(( ${UE_RESTARTS[$n]:-0} + 1 ))
      echo "      restarting UE ${n} (attempt ${UE_RESTARTS[$n]}/${MAX_UE_RESTARTS})..." >&2
      start_one_ue "${n}"
    else
      echo "      not restarting UE ${n} (RESTART_UES=${RESTART_UES}, restarts=${UE_RESTARTS[$n]:-0}/${MAX_UE_RESTARTS})." >&2
      unset 'UE_PID[$n]'
    fi
  done
done
