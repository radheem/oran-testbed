# SETUP

Per-component reference. For the scripted ZMQ end-to-end test see
[RUNBOOK_E2E_ZMQ.md](RUNBOOK_E2E_ZMQ.md).

## Concepts

- **Host ports vs docker-net.** 5GC (`38412/sctp` N2, `2152/udp` NG-U, `9999`
  WebUI) and RIC (`36421/sctp` E2, `8080`) publish on the host so multiple/remote
  gNBs can attach. gNB containers publish nothing; local gNBs use the shared
  `n2`/`oran-sc-ric` bridges, remote gNBs use the host ports.
- **N3 naming.** The `n3` bridge here is the **ZMQ RF transport wire** between the
  gNB and `multi_ue` — *not* the 3GPP N3. The real NG-U GTP-U runs over `n2`
  (5GC `10.53.1.2` ↔ gNB `10.53.1.3`).
- **gNB image.** Pulled by default (`GNB_IMAGE` in `.env`). The OCUDU source is
  vendored at `src/ocudu/`, so it can also be built locally:
  ```bash
  docker build -f src/ocudu/docker/Dockerfile \
    --build-arg ENABLE_ZEROMQ=On --build-arg MARCH=x86-64-v4 \
    -t rptestbed/gnb:local src/ocudu
  ```
  Set `MARCH` ≤ the run host's CPU ISA or the gNB SIGILLs (exit 132) once the PHY
  runs (testbed = Cascade Lake / `x86-64-v4`). Note the OCUDU build uses the
  **plural** `addrs`/`bind_addrs` config schema; the prebuilt srsRAN `gnb` image
  uses **singular** `addr`/`bind_addr` (see comments in `configs/gnb_zmq.yml`).

## 1. Networks
```bash
./scripts/net_manage.sh init      # n2, n3, oran-sc-ric, metrics (bridges)
./scripts/net_manage.sh dnet
./scripts/net_manage.sh remove
```
Subnets are overridable via the root `.env`.

## 2. Open5GS core
Built from `open5gs/`. The entrypoint:
- renders `open5gs-5gc.template.yml` (`${VARS}` from `open5gs/open5gs.env`) → `open5gs-5gc.yml`,
- provisions the `SUBSCRIBER_DB` subscriber via canonical `open5gs-dbctl`,
- adds the UPF egress `MASQUERADE` so UEs reach the internet.

```bash
./scripts/manage.sh start core
./scripts/add_user.sh 001010000000002      # add more UEs at runtime
./scripts/get_open5gs_subscribers.sh       # list
```
WebUI: http://localhost:9999 (admin / 1423).

Key `open5gs/open5gs.env` values: `OPEN5GS_IP=10.53.1.2`, `UE_IP_BASE=10.45.0`,
`SUBSCRIBER_DB` (boot UE = multi_ue UE #1).

## 3. ORAN-SC RIC
```bash
./scripts/manage.sh start ric      # starts compose + _ric_heal
```
`_ric_heal` works around the e2mgr↔Redis startup race (e2mgr `restart:on-failure`
in `ric/docker-compose.yml`; e2term restarted once e2mgr is up). xApps:
```bash
cd ric && docker compose exec python_xapp_runner ./kpm_mon_xapp.py --kpm_report_style 1
```

## 4. gNB

### ZMQ
`configs/gnb_zmq.yml` — `device_driver: zmq`,
`device_args tx_port=tcp://10.10.3.231:2000,rx_port=tcp://10.10.4.237:2001`,
E2 enabled to the RIC. UE side = `ue/multi_ue`.
```bash
DEPLOY_TYPE=zmq ./scripts/manage.sh start gnb
```

### UHD
`configs/gnb_uhd.yml` — set `device_args serial=` (`uhd_find_devices`). Real
handset as UE. Run host performance tuning before bring-up (low-latency
scheduling), then:
```bash
# .env -> DEPLOY_TYPE=uhd
./scripts/manage.sh start gnb
```
Handset with a custom slice SD (e.g. `0x111111`): add `sd:` under both
`cell_cfg.slicing` / `tai_slice_support_list` in `configs/gnb_uhd.yml` **and** on
the subscriber in the WebUI, else the AMF won't authorize it.

## 5. UE — multi_ue (ZMQ)
`ue/multi_ue` runs N srsUEs in one container sharing `10.10.4.237`, multiplexed
by ZMQ port, with a co-located bridge. `NUM_UES` is bounded by provisioned
subscribers. Single-cell by default (`CELL2_UES=` empty). ~2 UEs/cell attach
reliably (PRACH contention); for more, split across cells via `CELL2_UES` + a
second gNB.
```bash
./scripts/manage.sh start multi_ue
```

## 6. Monitoring
```bash
./scripts/manage.sh start monitoring     # grafana :3300
```
`WS_URL` in `monitoring/.env` must point at the gNB metrics socket
(default `172.19.1.3:8001`).

## 6b. Metrics pub/sub pipeline
```bash
./scripts/manage.sh start pubsub     # kafka + mongo + influxdb2 + consumer
```
xApps publish KPM to Kafka topic `xapp-metrics` (via `lib/metrics_publisher.py`,
selected by `METRICS_BACKEND=kafka`). The consumer (`pubsub/consumer/`) fans each
message to three sinks:
- **InfluxDB 3** — `srsran/kpm` (Grafana / existing path)
- **MongoDB** — `metrics.kpm` (full document + `ingested_at_ns`)
- **InfluxDB 2** — `primary/srsran` measurement `kpm`, **port 8086**, token
  `yVd3kfodr60RZGMYHnY1` — same InfluxDB version the O-RAN AIMLFW uses, written
  as-is so the AIMLFW can consume it (point a feature group at bucket `srsran`,
  measurement `kpm`, fields `DRB_UEThpDl`/`DRB_UEThpUl`).

Verify (after the ZMQ e2e is up and the KPM xApp is running):
```bash
docker exec influxdb2 influx query --org primary --token yVd3kfodr60RZGMYHnY1 \
  'from(bucket:"srsran") |> range(start:-15m) |> filter(fn:(r)=> r._measurement=="kpm") |> last()'
docker exec metrics_mongo mongosh --quiet --eval \
  'db.getSiblingDB("metrics").kpm.countDocuments({xapp:"kpm"})'
```

## 7. Utilities
- `scripts/add_user.sh`, `scripts/get_open5gs_subscribers.sh` — subscribers
- `scripts/dockstatus.sh` — container status
- `scripts/net_manage.sh` — networks
- `scripts/manage.sh` — lifecycle
