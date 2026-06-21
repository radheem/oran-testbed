#!/bin/bash
#
# Start a srsUE instance inside the container.
# Self-contained: ensures /dev/net/tun, creates the UE netns, generates the
# config, installs the default route once the tunnel appears, then runs srsUE.
#
# Usage: start_ue.sh [ue-number]   (defaults to $UE_NUM, else 1)
#
set -euo pipefail

UE="${1:-${UE_NUM:-1}}"
NS="ue${UE}"
NSFILE="/run/netns/${NS}"

GNB_IP="${GNB_IP:-10.10.3.231}"
UE_BIND_IP="${UE_BIND_IP:-*}"
UE_ZMQ_MODE="${UE_ZMQ_MODE:-bridge}"
ZMQ_BRIDGE_IP="${ZMQ_BRIDGE_IP:-10.10.4.237}"
UE_DNS1="${UE_DNS1:-1.1.1.1}"
UE_DNS2="${UE_DNS2:-8.8.8.8}"
ROUTE_WAIT_SECONDS="${ROUTE_WAIT_SECONDS:-120}"

# Ensure the TUN device node exists (needed for srsUE to create tun_srsue).
mkdir -p /dev/net
[ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200

# netns hygiene: drop a stale mountpoint that is not a valid namespace.
if [ -e "${NSFILE}" ] && ! ip netns list | grep -qw "${NS}"; then
  echo "Removing stale netns file ${NSFILE}"
  rm -f "${NSFILE}"
fi

ip netns add "${NS}" 2>/dev/null || true
ip netns exec "${NS}" ip link set lo up 2>/dev/null || true

# Per-netns resolver (avoid the container stub resolver inside the UE netns).
mkdir -p "/etc/netns/${NS}"
cat > "/etc/netns/${NS}/resolv.conf" <<EOF
nameserver ${UE_DNS1}
nameserver ${UE_DNS2}
EOF

# Background: once tun_srsue appears in the netns, set the default route via it.
(
  for _ in $(seq 1 "${ROUTE_WAIT_SECONDS}"); do
    if ip netns exec "${NS}" ip link show tun_srsue >/dev/null 2>&1; then
      ip netns exec "${NS}" ip route replace default dev tun_srsue scope link || true
      exit 0
    fi
    sleep 1
  done
  echo "Warning: tun_srsue did not appear in ${NS} within ${ROUTE_WAIT_SECONDS}s" >&2
) &
ROUTE_HELPER_PID=$!
trap 'kill "${ROUTE_HELPER_PID}" 2>/dev/null || true' EXIT

# Generate the config for this UE.
python3 /srsran/config/generate_ue_conf.py "${UE}" /tmp/ \
  --mode "${UE_ZMQ_MODE}" --gnb-ip "${GNB_IP}" \
  --bridge-ip "${ZMQ_BRIDGE_IP}" --ue-bind-ip "${UE_BIND_IP}"

# srsUE runs in the container's main netns (binds ZMQ to the container IP); the
# [gw] netns setting in the config places tun_srsue inside ${NS}.
exec /opt/srsRAN_4G/build/srsue/src/srsue "/tmp/ue_${UE}.conf"
