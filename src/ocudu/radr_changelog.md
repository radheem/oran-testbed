# radr changelog

Tracks the changes made while migrating the srsRAN-docker (ZMQ) workflow onto the
newer OCUDU image, for end-to-end ZMQ testing on the testbed.

Target repo: https://github.com/radheem/cudu-deployment.git
Image namespace: `rptestbed` (built & pushed externally, then pulled on the test machine)

## 2026-06-10 — Single-cell ZMQ bring-up: working config + Open5GS fixes

Brought the single-cell ZMQ stack up end to end (5GC + gNB + 1 UE → ping google.com)
on the testbed images and fixed what blocked it.

### Deployment config (to match the images actually on the testbed)
- `docker/docker-compose.zmq.yml`: 5gc image `rptestbed/docker-5gc:latest`; gnb image
  `rptestbed/gnb:20260610-dpdk` (the today-built ZMQ-enabled srsRAN image;
  `rptestbed/docker-gnb:latest` is a stale May build linked against `libmkl_rt.so.3`
  that isn't shipped, so it can't start — rebuild needed if that tag is wanted).
- `configs/gnb_zmq.yml` + `gnb_zmq_compose_config.yml`: AMF keys reverted to the
  **singular** `addr`/`bind_addr` — the running gnb image is a srsRAN build and rejects
  the plural `addrs`/`bind_addrs`.
- `multi_ue/.env`: `NUM_UES=1`, `CELL2_UES=""` (single UE, single cell).

### Open5GS image fixes (issues found at runtime; require an image rebuild)
- **#4 subscriber provisioning** — `add_users.py` produced subscriber docs this Open5GS
  release's UDR rejected for AccessAndMobilitySubscriptionData ("Cannot find SUPI in DB"
  → Registration reject), even with `security.sqn` added. Switched to the canonical
  `open5gs-dbctl`. **Removed `docker/open5gs/add_users.py`** (and dropped it from the
  Dockerfile COPY); the entrypoint now provisions the default subscriber via
  `open5gs-dbctl add`. **Removed `scripts/open5gs_add_ue.sh`**, replaced by
  **`scripts/add_user.sh`** which `docker exec`s `open5gs-dbctl` (defaults to multi_ue UE #1).
- **#5 UPF egress NAT** — `setup_tun.py`'s iptc MASQUERADE targets the tun device and
  lands in a different iptables backend, so UE traffic was never NAT'd to the internet.
  The entrypoint now adds `iptables -t nat -A POSTROUTING -s <pool>/16 ! -o ogstun -j
  MASQUERADE` explicitly (idempotent), so attached UEs can reach the internet.

### Runtime note
These two are baked into the Open5GS image/entrypoint; until the image is rebuilt, a
running stack still needs the manual equivalents (`scripts/add_user.sh` + the masquerade
rule). Verified end to end: UE attaches, gets `10.45.0.2`, `ping google.com` 0% loss.

## 2026-06-10 — Enable ZeroMQ + UHD drivers

### Goal
The OCUDU Dockerfile dropped the ZeroMQ RF driver that the old srsRAN image shipped.
Re-enable ZMQ (UHD is already built from source and `-DENABLE_UHD=On`) so the new image
can run the existing srsRAN ZMQ end-to-end test (scripts + multi_ue).

### `docker/Dockerfile`
- Added `ARG ENABLE_ZEROMQ=On` (top-level) and documented it in the build-args header.
  Toggleable via `--build-arg ENABLE_ZEROMQ=Off`.
- `builder-base` stage: install `libzmq3-dev` (ZeroMQ build dependency) after the
  existing dependency scripts. Needed by `-DENABLE_ZEROMQ`.
- `builder` stage: declared `ARG ENABLE_ZEROMQ` and passed
  `-DENABLE_ZEROMQ=${ENABLE_ZEROMQ}` to `builder.sh` alongside the existing
  `-DENABLE_UHD=On -DENABLE_DPDK=On`.
- `runtime` stage: install `libzmq5` (ZeroMQ runtime library) for ENABLE_ZEROMQ builds.
- UHD: no change required — UHD is built from source in the `builder-uhd` stage and
  `-DENABLE_UHD=On` was already set; UHD libs/paths are already wired into the runtime.

### `docker/docker-compose.yml`
- Renamed gnb image `ocudu/gnb` -> `rptestbed/gnb` (push target on the testbed).
- Added build arg `ENABLE_ZEROMQ: "On"`.

### `docker/docker-compose.split.yml`
- Renamed `ocudu/gnb` -> `rptestbed/gnb` across the gnb/cu-cp/cu-up/du services.
- Added build arg `ENABLE_ZEROMQ: "On"`; bumped default `OS_VERSION` 24.04 -> 26.04 to
  match the base compose file.

### Git
- Preserved upstream OCUDU remote as `upstream` (gitlab.com/ocudu/ocudu.git); set
  `origin` to the migration repo (github.com/radheem/cudu-deployment.git).

### Not done yet / next steps
- Provide/adjust a gnb config using the `zmq` RF driver for the end-to-end test.
- `docker-compose.ui.yml` images (`ocudu/telegraf`, `ocudu/grafana`) left unchanged —
  not part of the gnb build/push. Update if the metrics UI is also rehosted under rptestbed.

## 2026-06-10 — Import ZMQ test harness (multi_ue + utils)

Imported from the srsRAN-docker workspace to drive ZMQ end-to-end tests against the
new image. Scope: `multi_ue/` + standalone utility scripts only (per decision —
`manage.sh` was **not** imported, as it is wired to the srsRAN-docker workspace
layout: `gnb-zmq`/`gnb-uhd`, `oran-sc-ric`, `ue/`).

### `multi_ue/` (copied verbatim)
- One container hosting N srsUEs (prebuilt image `ghcr.io/sulaimanalmani/srsranzmq/srsue`)
  + co-located ZMQ bridge, single-IP/port-multiplexed model. Self-contained: uses the
  external `ue_n3` and `metrics` networks and its own `config/` + `.env`.
- Paths like `/srsran/config` and `/opt/srsRAN_4G/...` are **inside the prebuilt UE
  image** — intentionally left as-is.

### `scripts/` utilities (copied; gnb/open5gs refs adapted to ocudu)
- `docker_cleanup.sh` — gNB container names `srsran_gnb` -> `ocudu_gnb` (+ split
  `ocudu_cu_cp`/`ocudu_cu_up`/`ocudu_du`); UE group -> `multi_ue`.
- `open5gs_add_ue.sh` — add_users.py source path `../srsRAN_Project/docker/open5gs/`
  -> `../docker/open5gs/` (ocudu layout). `OPEN5GS_CONTAINER` default `open5gs_5gc` matches.
- `net_manage.sh`, `dockstatus.sh`, `get_5gc_live_config.sh`,
  `get_open5gs_subscribers.sh`, `update_slice.sh` — copied as-is (target `open5gs_5gc`,
  which matches; RIC bits are parameterized and unused unless a RIC is run).

### Testbed values to review before running
- `multi_ue/.env`: `GNB_IP` (10.10.3.231), `UE_HOST_IP` (10.10.4.237), `NUM_UES`,
  `CELL2_UES`, and `INFLUX_BUCKET=srsran` — tune for the ocudu testbed.
- The `ue_n3` + `metrics` external networks must exist before `multi_ue` starts
  (`scripts/net_manage.sh` can create them).

## 2026-06-10 — Single-cell ZMQ network setup + gNB config

Pulled the **single-cell** ZMQ network topology and gNB config from the
srsRAN-docker `gnb-zmq-single-cell` setup (two-cell variant ignored), placed
into the OCUDU directory structure. **Open5GS config was not touched** — the new
compose reuses the existing `docker/open5gs` build/env/command verbatim.

### `configs/gnb_zmq.yml` (new)
- Single-cell ZMQ gNB config: `ru_sdr.device_driver: zmq`,
  `device_args` tx `tcp://10.10.3.231:2000` / rx `tcp://10.10.4.237:2001`, PCI 1,
  slice sst=1, E2 disabled (no RIC).
- **Schema adapted to the new OCUDU build**: `cu_cp.amf.addr`/`bind_addr`
  (singular, old srsRAN) -> `addrs`/`bind_addrs` (plural), matching
  `configs/amf.yml` / `configs/gnb_rf_b200_tdd_n78_20mhz.yml`. Without this the
  new gnb binary rejects the config.

### `configs/gnb_zmq_compose_config.yml` (new)
- Compose-time overlay (2nd `-c`): amf addrs/bind_addrs + metrics layers +
  `remote_control`. Same `addr`->`addrs` adaptation. Collapsed a duplicate
  `layers:` key from the source (YAML last-wins) into one block.

### `docker/docker-compose.zmq.yml` (new)
- Self-contained single-cell ZMQ stack (5gc + gnb). gNB on `n2` (10.53.1.3),
  `n3` (10.10.3.231), `metrics` (172.19.1.3); mounts the two configs above.
- Networks `n2`/`n3`/`metrics` are **external** — create with
  `./scripts/net_manage.sh init`. UE side is `multi_ue/` (on ue_n3); run separately.
- 5gc mirrors the base compose (Open5GS unchanged) but attaches to `n2` (same
  10.53.1.2) + `default` (N6 egress). gNB image `rptestbed/gnb`, `ENABLE_ZEROMQ=On`.
- Validated with `docker compose -f docker/docker-compose.zmq.yml config`.

### Note
- Do not run the base `docker-compose.yml` and `docker-compose.zmq.yml` at the
  same time — both define `5gc`/`gnb`. The base file (ran/metrics, non-ZMQ) is
  left untouched.
