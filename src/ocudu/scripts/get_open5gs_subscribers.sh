#!/usr/bin/env bash
set -euo pipefail

# Prints Open5GS MongoDB subscriber entries from the running open5gs_5gc container.
# Usage:
#   ./scripts/get_open5gs_subscribers.sh
#   ./scripts/get_open5gs_subscribers.sh '{imsi: "001010000000001"}'
#   ./scripts/get_open5gs_subscribers.sh '{}' '{_id:0,imsi:1,slice:1}'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER_NAME="${OPEN5GS_CONTAINER:-open5gs_5gc}"
MINIMAL=false
QUERY="{}"
FIELDS="{_id:0,imsi:1,slice:1}"

usage() {
  cat <<EOF
Usage: ${0##*/} [--minimal] [--container NAME] [--query QUERY] [--fields FIELDS]

Options:
  --minimal, -m       Print minimal subscriber info (IMSI, APN, IPv4) instead of full documents.
  --container, -c     Open5GS container name (default: ${CONTAINER_NAME}).
  --query, -q         MongoDB query object (default: {}).
  --fields, -f        MongoDB projection object (default: ${FIELDS}).
  --help, -h          Show this help message.

Examples:
  ${0##*/}
  ${0##*/} --minimal
  ${0##*/} --query '{imsi: "001010000000001"}'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --minimal|-m)
      MINIMAL=true
      shift
      ;;
    --container|-c)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --query|-q)
      QUERY="$2"
      shift 2
      ;;
    --fields|-f)
      FIELDS="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "Error: Open5GS container '${CONTAINER_NAME}' is not running or not found." >&2
  exit 1
fi

CLIENT_BIN=$(docker exec "${CONTAINER_NAME}" bash -lc 'command -v mongosh || command -v mongo || true')
if [[ -z "${CLIENT_BIN}" ]]; then
  echo "Error: neither mongosh nor mongo is installed in the Open5GS container." >&2
  exit 1
fi

# Use the detected MongoDB shell to query the open5gs database.
if [[ "${MINIMAL}" == true ]]; then
  docker exec "${CONTAINER_NAME}" "${CLIENT_BIN}" --quiet open5gs --eval \
    "printjson(db.subscribers.find(${QUERY}, ${FIELDS}).map(function(s) { \
      var apn = null; var ipv4 = null; \
      if (Array.isArray(s.slice)) { \
        s.slice.forEach(function(sl) { \
          if (Array.isArray(sl.session)) { \
            sl.session.forEach(function(sess) { \
              if (sess.name && sess.name !== 'ims') { \
                apn = sess.name; \
                if (sess.ue && sess.ue.ipv4) { ipv4 = sess.ue.ipv4; } \
              } \
            }); \
          } \
        }); \
      } \
      return {imsi: s.imsi, apn: apn, ipv4: ipv4}; \
    }));"
else
  docker exec "${CONTAINER_NAME}" "${CLIENT_BIN}" --quiet open5gs --eval "printjson(db.subscribers.find(${QUERY}, ${FIELDS}).toArray())"
fi
