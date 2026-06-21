# Runbook — ZMQ end-to-end (RIC + Open5GS + UE)

Brings up the full ZMQ stack and verifies a UE attaches, reaches the internet,
and that the RIC receives E2/KPM metrics. Each step has a **gate** — don't
proceed until it passes.

Prereqs: docker, the `GNB_IMAGE` reachable (pull or already present), and the
`open5gs`/RIC images buildable/pullable.

## 0. Networks
```bash
./scripts/net_manage.sh init
./scripts/net_manage.sh dnet      # expect n2, n3, oran-sc-ric, metrics
```

## 1. Core (5GC)
```bash
./scripts/manage.sh start core
docker ps --filter name=open5gs_5gc --format '{{.Status}}'   # -> healthy
docker logs open5gs_5gc 2>&1 | grep -i "subscriber\|SUBSCRIBER_DB"
```
**Gate:** container `healthy`; log shows UE #1 (`001010000000001`) provisioned via
`open5gs-dbctl`. Host ports up: `ss -lnp | grep -E '38412|2152|9999'`.

UE #1 is boot-provisioned (see `open5gs/open5gs.env`). For more UEs:
```bash
./scripts/add_user.sh 001010000000002
```

## 2. RIC
```bash
./scripts/manage.sh start ric      # runs _ric_heal automatically
docker exec ric_dbaas redis-cli ping        # -> PONG
```
**Gate:** `ric_e2mgr` and `ric_e2term` are `Up`. Host port `36421/sctp` published.
If `e2mgr` is restarting, `_ric_heal` should settle it; otherwise
`docker logs ric_e2mgr`.

## 3. Monitoring
```bash
./scripts/manage.sh start monitoring
curl -fs http://localhost:3300/api/health     # grafana
```
**Gate:** influxdb `healthy`, grafana reachable on :3300.

## 4. gNB (ZMQ)
```bash
./scripts/manage.sh start gnb
docker exec ocudu_gnb sh -c 'grep -aE "NG setup|cell.*configured|Waiting for data" /tmp/gnb.log | tail'
```
**Gate A (NGAP):** `NG setup procedure successful` (gNB ↔ AMF over n2).
**Gate B (E2):** the DU registers in the RIC RNIB:
```bash
docker exec ric_dbaas redis-cli keys '*RAN:gnbd*'   # -> ...gnbd_001_001_000001_0
```
If no `gnbd_` node appears, confirm `e2sm_ccc_enabled: false` in `configs/gnb_zmq.yml`
(CCC on blocks DU E2 setup).

## 5. UE (multi_ue)
```bash
./scripts/manage.sh start multi_ue
docker exec multi_ue sh -c 'grep -aE "RRC Connected|PDU Session" /tmp/ue1.log | tail -2'
docker exec multi_ue ip netns exec ue1 ip addr show tun_srsue   # -> 10.45.0.x
docker exec multi_ue ip netns exec ue1 ping -c2 10.45.0.1        # gateway
docker exec multi_ue ip netns exec ue1 ping -c2 google.com       # internet (UPF NAT)
```
**Gate:** UE gets `10.45.0.2`, gateway + internet ping 0% loss.

> If the UE is stuck `Attaching...` and gnb.log shows `Completed 0 of 23040
> samples`, the ZMQ stream desynced. Clean restart:
> `manage.sh stop multi_ue` → `manage.sh stop gnb` → `manage.sh start gnb` →
> `manage.sh start multi_ue`.

## 6. RIC xApp (KPM)
Start InfluxDB first (the xApp pushes KPM into measurement `kpm`, bucket `srsran`):
```bash
./scripts/manage.sh start monitoring     # or: up -d influxdb
cd ric
docker compose exec python_xapp_runner ./kpm_mon_xapp.py \
  --e2_node_id gnbd_001_001_000001_0 --kpm_report_style 1 \
  --metrics DRB.UEThpDl,DRB.UEThpUl
```
**Gate A (subscription):** the xApp prints
`Successfully subscribed ... -> 1` and submgr returns `200`.
**Gate B (indications):** KPM rows land in InfluxDB:
```bash
docker exec influxdb sh -c "curl -s -G 'http://localhost:8081/api/v3/query_sql' \
  --data-urlencode 'db=srsran' \
  --data-urlencode 'q=SELECT * FROM kpm ORDER BY time DESC LIMIT 5'"
# -> {"DRB_UEThpDl":..,"DRB_UEThpUl":..,"e2_node_id":"gnbd_001_001_000001_0",...}
```

> **Operational notes (learned during bring-up):**
> - Run **one** xApp instance. `docker compose exec` processes that are killed
>   by a client-side `timeout`/Ctrl-C keep running **inside** the container and
>   hold the RMR (4560) / HTTP (8080) ports → the next run dies with
>   `Address already in use`. Clear them with `docker restart python_xapp_runner`.
> - First indications can log `RMR_ERR_NOENDPT` on `ric_e2term` until the xApp's
>   RMR endpoint (`10.0.2.20:4560`, route `12050` in `ric/configs/routes.rtg`) is
>   up — it self-resolves once the xApp is subscribed; errors then stop.
> - The xApp's stdout is line-buffered (`PYTHONUNBUFFERED=0` in the RIC compose);
>   prefer the InfluxDB gate over watching stdout.
> - Find live DU node ids: `docker exec ric_dbaas redis-cli keys '*RAN:gnbd*'`.

## 7. Traffic + telemetry
```bash
docker exec -d open5gs_5gc iperf3 -s -p 5201
docker exec multi_ue /srsran/config/run_scenario.sh \
  --video-client --bitrate 1M --server-ip 10.45.0.1 --port 5201 --ue 1 --duration 20
```
**Gate:** per-UE samples land in InfluxDB:
```bash
docker exec influxdb sh -c "curl -s -G 'http://localhost:8081/api/v3/query_sql' \
  --data-urlencode 'db=srsran' \
  --data-urlencode 'q=SELECT ue_id, count(*) AS n FROM ue_traffic GROUP BY ue_id'"
```
View the **Multi-UE Traffic** dashboard in Grafana (http://localhost:3300).

## Teardown
```bash
./scripts/manage.sh stop all
./scripts/net_manage.sh remove
```
