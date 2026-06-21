# Runbook — Single-cell ZMQ end-to-end test

Bring up **Open5GS 5GC + OCUDU gNB (ZMQ RF) + one srsUE** and confirm the UE attaches,
gets an IP, and can `ping google.com` from its network namespace. No SDR hardware — the
RF link is ZeroMQ over TCP.

- Repo root: `/home/radr/pers/internship/ocudu`
- Scope: single cell, single UE. (multi-UE / two-cell / RIC / monitoring are out of scope.)
- Per-issue history & deep dives: [`docs/journal/`](./journal/README.md).

---

## 1. Architecture

```
 multi_ue container (netns ue1)                      ocudu_gnb            open5gs_5gc
 ┌───────────────────────────┐   ZMQ (TCP)      ┌──────────────┐  N2/NGAP  ┌──────────┐
 │ srsUE → tun_srsue          │  uplink :2001    │ gNB (ZMQ RF) │──10.53.1.2│  AMF/SMF │
 │ + co-located ZMQ bridge    │ ───────────────► │ n3 10.10.3.231│  GTP-U    │  UPF     │
 │ UE_HOST_IP 10.10.4.237     │ ◄─────────────── │ n2 10.53.1.3 │◄─────────►│ ogstun   │
 └───────────────────────────┘  downlink :2000   └──────────────┘           │10.45.0.1 │
        on ue_n3 (10.10.4.0/24)                     on n2/n3/metrics         └────┬─────┘
                                                                          MASQUERADE│ eth0
 UE data: ue1 → tun_srsue → ZMQ → gNB → GTP-U → UPF ogstun → NAT → internet ───────┘
```

- **ue_n3 ↔ n3 routing** (host macvlan shims + iptables) lets the UE bridge (10.10.4.237)
  and the gNB (10.10.3.231) exchange ZMQ samples. Set up by `scripts/net_manage.sh`.
- **N2/NGAP and GTP-U** ride the `n2` network (5GC at 10.53.1.2). The docker `n3`
  network only carries the ZMQ RF transport.

## 2. Prerequisites

- Docker + compose v2, run as a user that can `docker` (the test execs into containers).
- Images present on the host (built/pulled):
  - `rptestbed/docker-5gc:<tag>` — Open5GS core
  - `rptestbed/docker-gnb:<tag>` — OCUDU gNB (must be built with `ENABLE_ZEROMQ=On`)
  - `ghcr.io/sulaimanalmani/srsranzmq/srsue:v1.1` — prebuilt srsUE (pulled automatically)
- **CPU / `MARCH` caveat (critical):** the gNB image must be built for an ISA **≤ the
  test host's CPU**. Building with `-march=native` on a newer machine and running on an
  older one crashes the gNB with **SIGILL (exit 132)** the moment PHY runs. Build on the
  test host, or `--build-arg MARCH=x86-64-v4` (Cascade Lake) / `x86-64-v3` (older).
  See [SIGILL journal](./journal/20260611-gnb-sigill-march-native.md).
- The compose file in use is **`docker/docker-compose.zmq.yml`** — update its `image:`
  tags to the tag you built (e.g. `:11062026`). Do **not** run the base
  `docker-compose.yml` at the same time (both define `5gc`/`gnb`).

## 3. Key files

| File | Role |
|------|------|
| `docker/docker-compose.zmq.yml` | 5GC + gNB stack (external `n2`/`n3`/`metrics` nets) |
| `configs/gnb_zmq.yml` | gNB ZMQ RF config (driver, ports, cell, `tx/rx_gain: 0`) |
| `configs/gnb_zmq_compose_config.yml` | gNB compose overlay (amf addrs, metrics) |
| `multi_ue/docker-compose.yaml` + `multi_ue/.env` | UE container (`NUM_UES=1`, `CELL2_UES=""`) |
| `scripts/net_manage.sh` | create/destroy the docker networks + host routing |
| `scripts/add_user.sh` | add a subscriber to Open5GS via `open5gs-dbctl` |

## 4. Procedure

All commands from the repo root.

### 4.1 Create networks (once per host boot)
```bash
./scripts/net_manage.sh init      # sudo; creates n2/n3/metrics/ue_n3 + host shims + NAT
```
- Needs `sudo` (host macvlan interfaces + iptables). If the default-route NIC is wrong,
  prefix `PARENT_IF=<nic>`.
- Idempotent — re-running skips existing networks. Check with `./scripts/net_manage.sh dnet`.

### 4.2 Deploy 5GC + gNB
```bash
docker compose -f docker/docker-compose.zmq.yml up -d      # no --build (use prebuilt images)
```
Wait for readiness:
```bash
docker inspect -f '{{.State.Health.Status}}' open5gs_5gc   # -> healthy
docker exec ocudu_gnb sh -c 'grep -c "Waiting for data" /tmp/gnb.log'   # -> > 0
```
The gNB logs to `/tmp/gnb.log` (config parse errors print to `docker logs ocudu_gnb`).
The new 5GC entrypoint automatically installs the UPF MASQUERADE and seeds the default
subscriber via `open5gs-dbctl`.

### 4.3 Provision the UE subscriber
```bash
./scripts/add_user.sh             # defaults to multi_ue UE #1 (IMSI 001010000000001)
```
This `docker exec`s `open5gs-dbctl add <imsi> <key> <opc>` (remove-then-add, idempotent).
Verify:
```bash
docker exec open5gs_5gc mongosh --quiet open5gs --eval \
  'db.subscribers.find({imsi:"001010000000001"}).forEach(d=>print(d.imsi))'
```

### 4.4 Start the UE (ZMQ lockstep — only after the gNB is "Waiting for data")
```bash
docker compose -f multi_ue/docker-compose.yaml up -d
```

### 4.5 Verify
```bash
# attach + PDU session
docker exec multi_ue ip netns exec ue1 ip -br addr show tun_srsue   # -> 10.45.x.x
docker exec multi_ue ip netns exec ue1 ip route                     # -> default dev tun_srsue
docker exec multi_ue tail -5 /tmp/ue1.log                           # PDU Session ... successful
# core side
docker logs open5gs_5gc 2>&1 | grep -E "Registration complete|IPv4\[10.45"
# THE TEST
docker exec multi_ue ip netns exec ue1 ping -c4 google.com          # 0% loss == PASS
docker exec multi_ue ip netns exec ue1 ping -c4 8.8.8.8             # isolates data vs DNS
```

## 5. Teardown
```bash
docker compose -f multi_ue/docker-compose.yaml down
docker compose -f docker/docker-compose.zmq.yml down
# networks persist; to remove them:  ./scripts/net_manage.sh remove   (sudo)
```

## 6. Troubleshooting

| Symptom | Likely cause | Fix | Journal |
|---|---|---|---|
| gNB exits immediately; `error while loading shared libraries: libmkl_rt.so.3` | image links MKL but doesn't ship the runtime | rebuild gNB w/o MKL | [link](./journal/20260610-gnb-image-missing-libmkl-rt.md) |
| gNB exits; `INI was not able to parse cu_cp.amf.addrs` (or `.addr`) | config schema vs binary fork mismatch | ocudu build → plural `addrs/bind_addrs`; srsRAN → singular | [link](./journal/20260610-gnb-amf-config-schema-singular-vs-plural.md) |
| gNB exits; `Channel gain must be <= 0.0 dB for ZMQ-device` / `Invalid radio configuration` | tx/rx gain > 0 for ZMQ | set `tx_gain: 0` / `rx_gain: 0` in `configs/gnb_zmq.yml` | [link](./journal/20260611-ocudu-gnb-zmq-gain-must-be-zero.md) |
| gNB runs idle but **crashes (exit 132) when the UE connects**; AMF later logs `gNB-N2 connection refused` | SIGILL — `-march=native` built on a newer CPU than the test host | rebuild gNB with `MARCH` ≤ test CPU (`x86-64-v4`/build on host) | [link](./journal/20260611-gnb-sigill-march-native.md) |
| UE reaches RRC Connected then released; AMF `Cannot find SUPI in DB` / Registration reject | subscriber missing/malformed | provision with `./scripts/add_user.sh` (dbctl) | [link](./journal/20260610-ue-registration-cannot-find-supi.md) |
| UE attaches + has 10.45.x.x but `ping` 100% loss / DNS fails | UPF has no MASQUERADE for the UE pool | entrypoint installs it; if missing: `docker exec open5gs_5gc iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE` | [link](./journal/20260610-ue-no-internet-upf-masquerade-missing.md) |
| UE stuck at `Attaching...`, no RACH, after a UE-only restart | ZMQ lockstep desync | clean cycle: down UE → `docker restart ocudu_gnb` (wait "Waiting for data") → up UE | [link](./journal/20260610-zmq-lockstep-ue-reattach-needs-gnb-restart.md) |
| dbctl insert "succeeds" but AMF can't find the sub | subscriber landed in wrong Mongo DB | use `--db_uri=mongodb://<ip>/open5gs` (verify with `mongosh open5gs`) | [link](./journal/20260611-open5gs-default-subscriber-wrong-mongo-db.md) |

Useful inspection commands:
```bash
docker exec ocudu_gnb tail -f /tmp/gnb.log                 # gNB PHY/MAC/RRC
docker logs -f open5gs_5gc                                 # 5GC NFs (amf/smf/upf/udr…)
docker exec multi_ue tail -f /tmp/ue1.log                  # srsUE
docker inspect ocudu_gnb --format 'Running={{.State.Running}} ExitCode={{.State.ExitCode}}'
```

## 7. Reference values

| Item | Value |
|---|---|
| PLMN / slice / TAC | `00101` / sst 1 / 7 |
| Cell | PCI 1, band 3, dl_arfcn 368500, 20 MHz, srate 23.04 |
| gNB N2 / N3 IP | 10.53.1.3 / 10.10.3.231 |
| AMF (5GC) N2 IP | 10.53.1.2 |
| ZMQ ports (gNB) | tx `10.10.3.231:2000`, rx `10.10.4.237:2001` |
| UE bridge IP (ue_n3) | 10.10.4.237 (`multi_ue/.env` UE_HOST_IP) |
| UE pool / gateway / DNS | 10.45.0.0/16 / 10.45.0.1 / 8.8.8.8 |
| UE #1 IMSI / K / OPc | `001010000000001` / `465B5CE8B199B49FAA5F0A2EE238A6BC` / `E8ED289DEBA952E4283B54E88E6183CA` |
| APN | internet |

> Note: the OCUDU gNB uses the **plural** `addrs`/`bind_addrs` AMF schema and requires
> ZMQ device gain `<= 0.0 dB`. Subscribers must be provisioned with `open5gs-dbctl`
> (not the removed `add_users.py`).
