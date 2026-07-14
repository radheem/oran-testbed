# Kafka-First Metrics + Grafana E2E Testing Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement/verify this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate the end-to-end metrics pipeline (`xApp/UE -> Kafka -> Consumers -> InfluxDB v2/v3 + MongoDB -> Grafana`) under a live ZMQ-based 5G SA network run.

**Architecture:** Bring up the full ZMQ-based O-RAN testbed, run active traffic scenarios on the UEs, and verify metric flow across the Kafka broker, the three independent consumer sinks (InfluxDB 2, InfluxDB 3, and MongoDB), and the Grafana visualization layer.

**Tech Stack:** Docker, Docker Compose, Apache Kafka, InfluxDB v2, InfluxDB v3, MongoDB, Python (srsue, gNB, Kafka-Python, pymongo), Grafana.

---

## Known Gotchas & Operational Notes
Before starting the test, keep the following operational learnings in mind:
1. **ZMQ Lockstep Clock Desync:** ZMQ is a virtual RF transport and requires gNB and UE to exchange baseband samples in lockstep. If you stop/start only the UE container while gNB keeps running, the ZMQ stream desynces, leaving the UE stuck at `Attaching...` with no RACH transmission. **Workaround:** Always follow the clean, ordered cycle: `stop UE -> restart gNB -> start UE`.
2. **srsRAN KPM Getter Bug:** In the upstream srsRAN KPM measurement provider, the getters for radio quality (`CQI`, `RSRP`, `RSRQ`) hardcode index `0` and emit only a single record. Therefore, in any multi-UE run, **only UE 0 (index 0) will show non-zero radio metrics, while UE 1+ will report CQI=0, RSRP=0, and RSRQ=0**. This is expected. Throughput, PRB, delay, and volume metrics are correctly looped per UE and will populate correctly for all UEs.
3. **Host CPU Starvation under Load:** Heavy UDP traffic or high-volume iperf3 runs can starve the host CPU, causing ZMQ late/underflow warnings (`L` / `U` on stdout) and forcing UE disconnects. **Workaround:** Run client scenarios with limited bitrates (e.g. `--voip-client` or restricted `--bitrate 1M` on client runs) to preserve host resources.
4. **xApp Port lock:** Running multiple concurrent instances of the KPM xApp or killing an active RMR session via raw SIGKILL/Ctrl-C can leave zombie processes holding ports `4560` (RMR) and `8080` (HTTP) inside the `python_xapp_runner` container. **Workaround:** Clean them by restarting the runner container: `docker restart python_xapp_runner`.

---

## Task 1: Environment Cleanup & Network Initialization

**Files:**
- Run scripts: `./scripts/net_manage.sh`

- [ ] **Step 1: Tear down existing containers to avoid port/state conflicts**

Run:
```bash
./scripts/manage.sh stop all
```
Expected: All containers associated with core, ric, gnb, monitoring, pubsub, and multi_ue are cleanly stopped and removed.

- [ ] **Step 2: Re-initialize the external Docker network bridges**

Run:
```bash
./scripts/net_manage.sh remove
./scripts/net_manage.sh init
```
Expected: Output showing the removal of old networks and creation of:
- `n2` (`10.53.1.0/24`)
- `n3` (`10.10.0.0/16`)
- `oran-sc-ric` (`10.0.2.0/24`)
- `metrics` (`172.19.1.0/24`)

---

## Task 2: Bring Up the Core & Pub/Sub Pipeline

**Files:**
- Orchestrate: `./scripts/manage.sh`
- Configuration: `./docker-compose.pubsub.yml`

- [ ] **Step 1: Start 5G Core (Open5GS)**

Run:
```bash
./scripts/manage.sh start core
```
Expected: `open5gs_5gc` container starts and status becomes `healthy`.

- [ ] **Step 2: Start the Pub/Sub pipeline (Kafka, MongoDB, InfluxDB 2, and the 3 consumers)**

Run:
```bash
./scripts/manage.sh start pubsub
```
Expected:
- Container `kafka` starts and becomes `healthy`.
- Container `metrics_mongo` starts and becomes `healthy`.
- Container `influxdb2` starts and becomes `healthy`.
- Consumer containers `consumer_influx3`, `consumer_influx2`, and `consumer_mongo` start successfully.

- [ ] **Step 3: Verify the Kafka Broker health and Auto-Topic Creation**

Run:
```bash
docker logs kafka | grep -i "Kafka Server started"
```
Expected: Broker is active and listening on port `9092` internally.

- [ ] **Step 4: Verify Consumer connection to Kafka**

Run:
```bash
docker logs consumer_influx3 | grep -i "connected to Kafka"
```
Expected: Outputs `connected to Kafka kafka:9092 topic=xapp-metrics group=cons-influx3`.

---

## Task 3: Bring Up the RAN and Near-RT RIC

**Files:**
- Orchestrate: `./scripts/manage.sh`

- [ ] **Step 1: Start the Near-RT RIC**

Run:
```bash
./scripts/manage.sh start ric
```
Expected: Starts dbaas, e2term, e2mgr, submgr, rtmgr, and heals startup races. `ric_e2mgr` and `ric_e2term` containers must be `Up`.

- [ ] **Step 2: Start the gNB (OCUDU ZMQ)**

Run:
```bash
./scripts/manage.sh start gnb
```
Expected: DU container starts.

- [ ] **Step 3: Verify NG Setup (gNB ↔ Core)**

Run:
```bash
docker exec ocudu_gnb sh -c 'grep -a "NG setup" /tmp/gnb.log'
```
Expected: Logs output `NG setup procedure successful` (S1-like interface registration with AMF).

- [ ] **Step 4: Verify E2 Setup (DU ↔ RIC)**

Run:
```bash
docker exec ric_dbaas redis-cli keys '*RAN:gnbd*'
```
Expected: Output matches `...gnbd_001_001_000001_0`, confirming the DU registered in the RIC RNIB.

---

## Task 4: Attach the UEs (multi_ue)

**Files:**
- Orchestrate: `./scripts/manage.sh`
- Code: `./ue/multi_ue/config/start_all.sh`

- [ ] **Step 1: Start multi_ue container**

Run:
```bash
./scripts/manage.sh start multi_ue
```
Expected: Starts the ZMQ bridge and spawns `srsue` instances inside local namespaces `ue1` and `ue2`.

- [ ] **Step 2: Verify UE Attach & RRC Connection**

Run:
```bash
docker exec multi_ue sh -c 'grep -aE "RRC Connected|PDU Session" /tmp/ue1.log | tail -2'
```
Expected:
- Output shows: `RRC Connected`
- Output shows: `PDU Session Establishment successful`
- UE 1 receives an IP from the Core (typically `10.45.0.2` on interface `tun_srsue`).

- [ ] **Step 3: Verify UE Internet Routing (UPF NAT / Masquerading)**

Run:
```bash
docker exec multi_ue ip netns exec ue1 ping -c3 google.com
```
Expected: `0% packet loss`, confirming that internet packets traverse `tun_srsue` and are successfully SNAT'd via the UPF's masquerading rules.

---

## Task 5: Start the RIC KPM xApp (E2 Kafka-First Producer)

**Files:**
- Exec container: `python_xapp_runner`
- Code: `/opt/xApps/kpm_mon_xapp.py`

- [ ] **Step 1: Launch the xApp over Kafka backend**

Run:
```bash
docker exec -d python_xapp_runner ./kpm_mon_xapp.py \
  --e2_node_id gnbd_001_001_000001_0 --kpm_report_style 1 \
  --metrics DRB.UEThpDl,DRB.UEThpUl
```
*(Note: Run in background `-d` so it continues executing asynchronously.)*

- [ ] **Step 2: Check xApp stdout logs for subscription**

Run:
```bash
docker logs python_xapp_runner 2>&1 | grep -i "Successfully subscribed"
```
Expected: Output shows `Successfully subscribed ... -> 1`.

- [ ] **Step 3: Verify KPM indications are published to Kafka**

Run:
```bash
docker logs consumer_influx3 | grep -E "processed.*messages"
```
Expected: Outputs periodic logs such as:
`[influx] processed 1 messages (last xapp=kpm)`
`[influx] processed 51 messages (last xapp=kpm)`

---

## Task 6: Start UE Traffic & Exporter Metrics (UE Kafka-First Producer)

**Files:**
- Exec container: `multi_ue`
- Run script: `/srsran/config/run_scenario.sh`

- [ ] **Step 1: Start iperf3 server in 5GC core container**

Run:
```bash
docker exec -d open5gs_5gc iperf3 -s -p 5201
```
Expected: Server launches in background listening on port 5201.

- [ ] **Step 2: Run UE Traffic scenario with Kafka-First export**

Run:
```bash
docker exec -d multi_ue /srsran/config/run_scenario.sh \
  --video-client --bitrate 1M --server-ip 10.45.0.1 --port 5201 --ue 1 --duration 30
```
*(Note: Using limited `--bitrate 1M` and run in background to allow live verification.)*

- [ ] **Step 3: Verify the exporter initialized the Kafka-Python producer**

Run:
```bash
docker logs multi_ue 2>&1 | grep -i "MetricsPublisher" -A2 || true
```
Expected: No Kafka warning. If Kafka was unreachable, it would output: `WARN: Kafka producer init failed`. A successful run emits nothing on stderr during initialization.

- [ ] **Step 4: Verify UE exporter metrics land in Kafka**

Run:
```bash
docker logs consumer_influx3 | grep -E "processed.*(last xapp=multi_ue)"
```
Expected: Consumer logs indicate processed messages sourced from `multi_ue`.

---

## Task 7: Database Gate Checks (Validate Consumer Sinks)

We must verify that all three independent consumers correctly deserialized the Kafka payloads and inserted them into their respective datastores.

- [ ] **Step 1: Check InfluxDB 3 (Grafana Datastore) — `consumer_influx3`**

Run:
```bash
docker exec influxdb sh -c "curl -s -G 'http://localhost:8081/api/v3/query_sql' \
  --data-urlencode 'db=srsran' \
  --data-urlencode 'q=SELECT * FROM kpm ORDER BY time DESC LIMIT 3'"
```
Expected: JSON rows containing KPM measurements (`DRB_UEThpDl`, `DRB_UEThpUl`, `e2_node_id`).

Run:
```bash
docker exec influxdb sh -c "curl -s -G 'http://localhost:8081/api/v3/query_sql' \
  --data-urlencode 'db=srsran' \
  --data-urlencode 'q=SELECT * FROM ue_traffic ORDER BY time DESC LIMIT 3'"
```
Expected: JSON rows containing traffic measurements (`throughput_mbps`, `ue_id`, `scenario`).

- [ ] **Step 2: Check InfluxDB 2 (AIMLFW Datastore) — `consumer_influx2`**

Run:
```bash
docker exec influxdb2 influx query --org primary -t yVd3kfodr60RZGMYHnY1 \
  'from(bucket: "srsran") |> range(start: -5m) |> filter(fn: (r) => r["_measurement"] == "kpm") |> limit(n: 3)'
```
Expected: Flux-annotated CSV rows representing KPM records written to the InfluxDB 2 bucket.

- [ ] **Step 3: Check MongoDB (rApp Datastore) — `consumer_mongo`**

Run:
```bash
docker exec metrics_mongo mongosh metrics --quiet --eval "db.kpm.find().sort({_id:-1}).limit(3).toArray()"
```
Expected: JSON documents with added metadata:
```json
{
  "_id": "...",
  "measurement": "kpm",
  "tags": { "e2_node_id": "gnbd_001_001_000001_0" },
  "fields": { "DRB_UEThpDl": 0, "DRB_UEThpUl": 0 },
  "timestamp_ns": 1783981290000000000,
  "xapp": "kpm",
  "ingested_at_ns": 1783981291000000000,
  "createdon": "2026-07-14T..."
}
```

Run:
```bash
docker exec metrics_mongo mongosh metrics --quiet --eval "db.ue_traffic.find().sort({_id:-1}).limit(3).toArray()"
```
Expected: JSON documents representing `ue_traffic` metrics.

---

## Task 8: Grafana Dashboard Verification

**Files:**
- Orchestrate: `./scripts/manage.sh`

- [ ] **Step 1: Start the Grafana and Telegraf monitoring containers**

Run:
```bash
./scripts/manage.sh start monitoring
```
Expected: Telegraf, InfluxDB, and Grafana start and are `Up`.

- [ ] **Step 2: Verify Grafana is accessible on host port 3300**

Run:
```bash
curl -fs http://localhost:3300/api/health
```
Expected: `{"database":"ok","ok":true}`

- [ ] **Step 3: Access Grafana in the browser**

Open: `http://localhost:3300` (Default credentials: `admin` / `admin` or as defined in `.env`).

- [ ] **Step 4: Verify the existence of the three new Kafka-fed dashboards**

Check the dashboard list in Grafana:
1. **`kpm_kafka`** (queries KPM measurements written by consumer_influx3)
2. **`multi_ue_traffic_kafka`** (queries UE traffic and latency measurements)
3. **`e2e_ue_kpm_gnb_kafka`** (combines E2 KPM and UE-sourced KPIs on a single timeline)

Expected: Dashboards are auto-loaded and display live telemetry matching the background traffic run.

- [ ] **Step 5: Verify the legacy dashboards still open and read legacy measurements**

Check that legacy dashboards like `performance` or `home` are unchanged and load without errors.

---

## Task 9: Clean Teardown

- [ ] **Step 1: Stop all testbed services**

Run:
```bash
./scripts/manage.sh stop all
./scripts/net_manage.sh remove
```
Expected: All docker containers are stopped, database volumes are preserved, and bridge networks are removed.
