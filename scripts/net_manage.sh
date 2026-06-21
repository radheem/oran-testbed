#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# net_manage.sh — create/remove the shared docker bridge networks.
#
# Simplified bridge-only model (no macvlan, no host interfaces, no sudo): every
# component attaches to these external bridges, and the 5GC + RIC publish host
# ports so additional/remote gNBs can attach too. gNB containers publish nothing.
#
#   n2          NGAP (SCTP) + NG-U GTP-U   5GC <-> gNB(s)
#   n3          ZMQ RF transport wire      gNB(s) <-> multi_ue   (NOT 3GPP N3)
#   oran-sc-ric E2                         gNB(s) <-> RIC
#   metrics     telemetry                  telegraf/influx/grafana/xApp/UE
#
# Usage: ./scripts/net_manage.sh init | remove | dnet
# ─────────────────────────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT_DIR/.env" ]] && { set -a; source "$ROOT_DIR/.env"; set +a; }

N2_SUBNET="${N2_SUBNET:-10.53.1.0/24}"
N3_SUBNET="${N3_SUBNET:-10.10.0.0/16}"
RIC_SUBNET="${RIC_SUBNET:-10.0.2.0/24}"
METRICS_SUBNET="${METRICS_SUBNET:-172.19.1.0/24}"

create_bridge() {
  local name="$1" subnet="$2"
  if docker network inspect "$name" >/dev/null 2>&1; then
    echo "network '$name' already exists — skipping"
  else
    echo "creating bridge network '$name' ($subnet)"
    docker network create --driver bridge --subnet "$subnet" "$name" >/dev/null
  fi
}

remove_bridge() {
  local name="$1"
  if docker network inspect "$name" >/dev/null 2>&1; then
    echo "removing network '$name'"
    docker network rm "$name" >/dev/null || echo "  (in use — stop containers first)"
  else
    echo "network '$name' does not exist — skipping"
  fi
}

case "${1:-init}" in
  init|create)
    create_bridge n2          "$N2_SUBNET"
    create_bridge n3          "$N3_SUBNET"
    create_bridge oran-sc-ric "$RIC_SUBNET"
    create_bridge metrics     "$METRICS_SUBNET"
    echo "done."
    ;;
  remove|cleanup)
    remove_bridge metrics
    remove_bridge oran-sc-ric
    remove_bridge n3
    remove_bridge n2
    echo "done."
    ;;
  dnet)
    docker network ls --format '{{.Name}}' | while read -r n; do
      sub=$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$n" 2>/dev/null)
      printf "%-20s %s\n" "$n" "$sub"
    done
    ;;
  *)
    echo "Usage: $0 init|remove|dnet" >&2; exit 1 ;;
esac
