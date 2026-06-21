#!/bin/bash

set -euo pipefail

# Cleanup specific Docker containers by subcommand or remove selected groups.
# Usage:
#   ./scripts/docker_cleanup.sh help
#   ./scripts/docker_cleanup.sh exited
#   ./scripts/docker_cleanup.sh ue
#   ./scripts/docker_cleanup.sh gnb
#   ./scripts/docker_cleanup.sh open5gs
#   ./scripts/docker_cleanup.sh oran
#   ./scripts/docker_cleanup.sh all
#   ./scripts/docker_cleanup.sh name...

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required but not installed."
    exit 1
fi

UE_CONTAINERS=(
    "multi_ue"
)

GNB_CONTAINERS=(
    "ocudu_gnb"
    "ocudu_cu_cp"
    "ocudu_cu_up"
    "ocudu_du"
)

OPEN5G_CONTAINERS=(
    "open5gs_5gc"
)

ORAN_CONTAINERS=(
    "ric_submgr"
    "python_xapp_runner"
    "ric_rtmgr_sim"
    "ric_e2term"
    "ric_dbaas"
    "ric_appmgr"
    "ric_e2mgr"
)

print_help() {
    cat <<EOF
Usage:
  $0 help           # show this help message
  $0 exited         # remove all exited containers
  $0 ue             # remove UE-related containers
  $0 gnb            # remove gNB container(s)
  $0 o5g            # remove Open5GS container(s)
  $0 oran           # remove ORAN-related containers
  $0 all            # remove UE, gNB, Open5GS, and ORAN containers
  $0 name...        # remove specific container names
EOF
}

remove_container() {
    local container="$1"

    if docker ps -a --format '{{.Names}}' | grep -xq "${container}"; then
        echo "Removing container: ${container}"
        docker rm -f "${container}"
    else
        echo "Skipping missing container: ${container}"
    fi
}

remove_list() {
    for name in "$@"; do
        remove_container "$name"
    done
}

remove_exited() {
    local exited

    exited=$(docker ps -a -f status=exited --format '{{.ID}}')
    if [ -z "${exited}" ]; then
        echo "No exited containers to remove."
        return
    fi

    echo "Removing exited containers:"
    docker rm ${exited}
}

if [ "$#" -eq 0 ]; then
    print_help
    exit 0
fi

case "$1" in
    help|-h|--help)
        print_help
        ;;
    exited)
        remove_exited
        ;;
    ue)
        remove_list "${UE_CONTAINERS[@]}"
        ;;
    gnb)
        remove_list "${GNB_CONTAINERS[@]}"
        ;;
    o5g)
        remove_list "${OPEN5G_CONTAINERS[@]}"
        ;;
    oran)
        remove_list "${ORAN_CONTAINERS[@]}"
        ;;
    all)
        remove_list "${UE_CONTAINERS[@]}"
        remove_list "${GNB_CONTAINERS[@]}"
        remove_list "${OPEN5G_CONTAINERS[@]}"
        remove_list "${ORAN_CONTAINERS[@]}"
        ;;
    *)
        remove_list "$@"
        ;;
esac
