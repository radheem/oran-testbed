#!/usr/bin/env bash
set -euo pipefail

# Add (or replace) a subscriber in the running Open5GS container using the
# canonical open5gs-dbctl tool. Replaces the old add_users.py-based flow, whose
# subscriber docs this Open5GS release's UDR rejected ("Cannot find SUPI in DB").
#
# Usage:
#   ./scripts/add_user.sh [imsi] [key] [opc] [container]
#
# With no args it provisions multi_ue UE #1 (defaults below match
# multi_ue/config/generate_ue_conf.py). Override per arg as needed, e.g.:
#   ./scripts/add_user.sh 001010000000002
#   OPEN5GS_CONTAINER=open5gs_5gc ./scripts/add_user.sh 001010000000001 <key> <opc>

CONTAINER="${OPEN5GS_CONTAINER:-open5gs_5gc}"
IMSI="${1:-001010000000001}"
KEY="${2:-465B5CE8B199B49FAA5F0A2EE238A6BC}"
OPC="${3:-E8ED289DEBA952E4283B54E88E6183CA}"
[ "$#" -ge 4 ] && CONTAINER="$4"

DBCTL=/open5gs/misc/db/open5gs-dbctl

if ! docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
  echo "Error: Open5GS container '${CONTAINER}' is not running or not found." >&2
  exit 1
fi

echo "Adding subscriber IMSI=${IMSI} to ${CONTAINER} via open5gs-dbctl..."
# remove-then-add makes re-runs idempotent (no duplicate-key error).
docker exec "${CONTAINER}" "${DBCTL}" remove "${IMSI}" >/dev/null 2>&1 || true
docker exec "${CONTAINER}" "${DBCTL}" add "${IMSI}" "${KEY}" "${OPC}"
echo "Done."
