#!/bin/bash
#
# Fan a traffic scenario out across ALL active UE netns concurrently. Each UE
# runs run_scenario.sh in its own netns ue<n> and exports throughput + latency
# to InfluxDB tagged by ue_id (so Grafana can break results down per UE).
#
# Pass any run_scenario.sh client/latency flags; --ue is added automatically.
#
# Examples:
#   run_all_scenarios.sh --voip-client  --server-ip 10.45.0.1
#   run_all_scenarios.sh --file-client  --server-ip 10.45.0.1 --duration 30
#   run_all_scenarios.sh --latency      --server-ip 8.8.8.8
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

N="${NUM_UES:-2}"

# Allow an explicit UE list: --ues "1,3,4" (otherwise 1..N).
UES=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ues) UES="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ -n "$UES" ]]; then
  IFS=',' read -r -a UE_LIST <<< "$UES"
else
  UE_LIST=()
  for n in $(seq 1 "$N"); do UE_LIST+=("$n"); done
fi

pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done' EXIT INT TERM

for n in "${UE_LIST[@]}"; do
  if ! ip netns list | grep -qw "ue${n}"; then
    echo "Skipping UE ${n}: netns ue${n} not found (is it started?)" >&2
    continue
  fi
  echo "=== UE ${n}: ${ARGS[*]} ==="
  "${HERE}/run_scenario.sh" "${ARGS[@]}" --ue "${n}" &
  pids+=($!)
done

if [[ ${#pids[@]} -eq 0 ]]; then
  echo "No UE netns available to run scenarios." >&2
  exit 1
fi

# Wait for all scenarios to finish; surface a non-zero exit if any failed.
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=$?; done
exit "$rc"
