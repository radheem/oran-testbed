#! /bin/bash

# SPDX-FileCopyrightText: Copyright (C) 2021-2026 Software Radio Systems Limited
# SPDX-License-Identifier: BSD-3-Clause-Open-MPI

export UE_GATEWAY_IP="${UE_IP_BASE}.1"
export UE_IP_RANGE="${UE_IP_BASE}.0/24"

INSTALL_ARCH=x86_64-linux-gnu
if [ "$(uname -m)" = "aarch64" ]; then
    INSTALL_ARCH="aarch64-linux-gnu"
fi
export INSTALL_ARCH

envsubst < open5gs-5gc.yml.in > open5gs-5gc.yml

# create dummy interfaces on localhost ip range for open5gs entities to bind to
for IP in {2..22}
do
    ip link add name lo$IP type dummy
    ip ad ad 127.0.0.$IP/24 dev lo$IP
    ip link set lo$IP up
done

# run webui
cd webui && npm run dev &

# run mongodb
mkdir -p /data/db && mongod --logpath /tmp/mongodb.log &

# wait for mongodb to be available, otherwise open5gs will not start correctly
while ! ( nc -zv $MONGODB_IP 27017 2>&1 >/dev/null )
do
    echo waiting for mongodb
    sleep 1
done

# setup ogstun and routing
python3 setup_tun.py --ip_range ${UE_IP_RANGE}
if [ $? -ne 0 ]
then
    echo "Failed to setup ogstun and routing"
    exit 1
fi

# Masquerade UE traffic out the egress interface so attached UEs reach the
# internet. setup_tun.py's iptc-based rule targets the tun device and lands in
# a different iptables backend (legacy vs nft), so it never takes effect on the
# forwarding path; add the working rule explicitly here. The UE pool spans the
# whole /16 (setup_tun.py creates 256 /24s under ${UE_IP_BASE%.*}.0.0/16).
UE_NAT_RANGE="${UE_IP_BASE%.*}.0.0/16"
if ! iptables -t nat -C POSTROUTING -s "${UE_NAT_RANGE}" ! -o ogstun -j MASQUERADE 2>/dev/null
then
    iptables -t nat -A POSTROUTING -s "${UE_NAT_RANGE}" ! -o ogstun -j MASQUERADE
fi

# Provision the default subscriber via the canonical open5gs-dbctl tool. (The
# old add_users.py produced subscriber docs that this Open5GS release's UDR
# rejected for AccessAndMobilitySubscriptionData -> "Cannot find SUPI in DB".)
# SUBSCRIBER_DB format: imsi,key,op_type,op/opc,amf,qci,ip[,apn]
echo "SUBSCRIBER_DB=${SUBSCRIBER_DB}"
DBCTL=/open5gs/misc/db/open5gs-dbctl
IFS=',' read -r SUB_IMSI SUB_KEY _SUB_OPTYPE SUB_OPC _SUB_REST <<< "${SUBSCRIBER_DB}"
SUB_IP="$(echo "${SUBSCRIBER_DB}" | cut -d, -f7)"
"${DBCTL}" --db_uri="mongodb://${MONGODB_IP}/open5gs" remove "${SUB_IMSI}" >/dev/null 2>&1 || true
if [ -n "${SUB_IP}" ]
then
    "${DBCTL}" --db_uri="mongodb://${MONGODB_IP}/open5gs" add "${SUB_IMSI}" "${SUB_IP}" "${SUB_KEY}" "${SUB_OPC}"
else
    "${DBCTL}" --db_uri="mongodb://${MONGODB_IP}/open5gs" add "${SUB_IMSI}" "${SUB_KEY}" "${SUB_OPC}"
fi
if [ $? -ne 0 ]
then
    echo "Failed to add subscribers to database"
    exit 1
fi

if $DEBUG
then
    exec stdbuf -o L gdb -batch -ex=run -ex=bt --args $@
else
    exec stdbuf -o L $@
fi
