#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# manage.sh — start/stop the cudu-deploy components.
#
#   ./scripts/manage.sh start|stop core        # Open5GS 5GC (host ports)
#   ./scripts/manage.sh start|stop ric         # ORAN-SC Near-RT RIC (host ports)
#   ./scripts/manage.sh start|stop gnb         # gNB (DEPLOY_TYPE=zmq|uhd), docker-net only
#   ./scripts/manage.sh start|stop multi_ue    # N srsUEs in one container (zmq only)
#   ./scripts/manage.sh start|stop monitoring  # telegraf + influxdb + grafana
#   ./scripts/manage.sh start|stop all         # core + ric + gnb + monitoring (+ multi_ue if zmq)
#
# Networks must exist first:  ./scripts/net_manage.sh init
# DEPLOY_TYPE (zmq|uhd) comes from the root .env (default zmq).
# ─────────────────────────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ -f "$ROOT_DIR/.env" ]] && { set -a; source "$ROOT_DIR/.env"; set +a; }
DEPLOY_TYPE="${DEPLOY_TYPE:-zmq}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { printf "${GREEN}[manage]  %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}[manage!] %s${NC}\n" "$*"; }
err()  { printf "${RED}[manage!] %s${NC}\n" "$*"; }

dc() { docker compose "$@"; }

# Compose invocations per component (paths relative to ROOT_DIR).
core()       { dc -f docker-compose.core.yml "$@"; }
gnb()        { dc -f "docker-compose.${DEPLOY_TYPE}.yml" "$@"; }
monitoring() { dc -f docker-compose.monitoring.yml --env-file monitoring/.env "$@"; }
multi_ue()   { dc -f ue/multi_ue/docker-compose.yaml --env-file ue/multi_ue/.env "$@"; }
pubsub()     { dc -f docker-compose.pubsub.yml "$@"; }
ric()        { ( cd ric && dc "$@" ); }

# ── RIC E2 startup-race heal ──────────────────────────────────────────────────
# e2mgr exits if Redis (dbaas) isn't ready within its 3x retry budget; e2term
# then can't route E2 (RMR_ERR_NOENDPT) and a connecting gNB segfaults on E2
# setup. e2mgr has restart:on-failure (ric compose) but e2term does not exit, so
# restart it once e2mgr is up to re-register the E2 route.
_ric_heal() {
    log "Settling RIC E2 path (e2mgr/Redis startup race)..."
    sleep 3
    docker start ric_e2mgr >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 20); do
        docker ps --filter name=ric_e2mgr --format '{{.Status}}' | grep -q Up && break
        sleep 1
    done
    docker restart ric_e2term >/dev/null 2>&1 || true
    sleep 2
    if docker ps --filter name=ric_e2mgr --format '{{.Status}}' | grep -q Up; then
        log "RIC E2 path ready (e2mgr up, e2term re-initialized)."
    else
        warn "RIC e2mgr still not up; check 'docker logs ric_e2mgr'."
    fi
}

do_component() {
    local comp="$1" action="$2"
    case "$comp" in
        core)       if [[ $action == up ]]; then log "Starting 5GC core"; core up -d; else log "Stopping core"; core down; fi ;;
        ric)        if [[ $action == up ]]; then log "Starting RIC"; ric up -d; _ric_heal; else log "Stopping RIC"; ric down; fi ;;
        gnb)        if [[ $action == up ]]; then log "Starting gNB ($DEPLOY_TYPE)"; gnb up -d; else log "Stopping gNB ($DEPLOY_TYPE)"; gnb down; fi ;;
        monitoring) if [[ $action == up ]]; then log "Starting monitoring"; monitoring up -d; else log "Stopping monitoring"; monitoring down; fi ;;
        pubsub)     if [[ $action == up ]]; then log "Starting pubsub (kafka+mongo+consumer)"; pubsub up -d; else log "Stopping pubsub"; pubsub down; fi ;;
        multi_ue)
            if [[ "$DEPLOY_TYPE" != zmq ]]; then warn "multi_ue is zmq-only (DEPLOY_TYPE=$DEPLOY_TYPE) — skipping"; return 0; fi
            if [[ $action == up ]]; then log "Starting multi_ue"; multi_ue up -d; else log "Stopping multi_ue"; multi_ue down; fi ;;
        all)
            if [[ $action == up ]]; then
                do_component core up; do_component monitoring up; do_component pubsub up
                do_component ric up; do_component gnb up
                [[ "$DEPLOY_TYPE" == zmq ]] && do_component multi_ue up || true
            else
                [[ "$DEPLOY_TYPE" == zmq ]] && do_component multi_ue down || true
                do_component gnb down; do_component ric down
                do_component pubsub down; do_component monitoring down; do_component core down
            fi ;;
        *) err "Unknown component: $comp"; usage; exit 1 ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <start|stop> <core|ric|gnb|multi_ue|monitoring|pubsub|all>
DEPLOY_TYPE=$DEPLOY_TYPE (set in $ROOT_DIR/.env). Run net_manage.sh init first.
EOF
}

[[ $# -lt 2 ]] && { usage; exit 1; }
case "$1" in
    start) ACTION=up ;;
    stop)  ACTION=down ;;
    *) err "Unknown action: $1 (use start|stop)"; usage; exit 1 ;;
esac
do_component "$2" "$ACTION"
