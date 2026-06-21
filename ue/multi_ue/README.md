# multi_ue — many srsUEs in one container

A single container that hosts **N srsUE instances** attached to the same gNB,
generates per-UE traffic, and exports throughput/latency to InfluxDB for Grafana.

This is the **single-IP, port-multiplexed** model (migrated from the k8s srsue
deployment), as opposed to the one-container-per-UE setup in `../ue/`.

## How it works

- **One container, one IP.** The container takes a single `ue_n3` address
  (`UE_HOST_IP`, default `10.10.4.237`). Every UE and the bridge bind their ZMQ
  sockets to that IP and are distinguished only by **port**.
- **Co-located bridge** (`config/multi_ue_scenario.py`, a GNU Radio flow graph):
  - gNB downlink `tcp://GNB_IP:2000` → summed/fanned → each UE
  - each UE uplink → summed → gNB `tcp://UE_HOST_IP:2001`
- **Per-UE ZMQ ports** (n = 1..N): uplink `2100+n`, downlink `2200+n`.
- **Per-UE netns** `ue<n>`; each srsUE places its `tun_srsue` there and the
  default route is auto-installed via the tunnel (see `start_ue.sh`).

Because the bridge binds the gNB-facing socket at `UE_HOST_IP:2001`, and the
gNB's `device_args rx_port` already points at `10.10.4.237:2001`, **no gNB
config change is required** as long as `UE_HOST_IP` stays `10.10.4.237`.

```
 gNB 10.10.3.231 :2000 ───────────────► bridge req_source ─┐
 gNB 10.10.3.231 ◄── :2001 UE_HOST_IP ── bridge rep_sink ◄─┴─ Σ uplinks
                                              │ fan-out
   UE1  tx :2101 / rx :2201  (netns ue1) ◄────┤
   UE2  tx :2102 / rx :2202  (netns ue2) ◄────┘   ... all on UE_HOST_IP
```

## Limits

`NUM_UES` is capped by the open5gs `subscriber_db.csv` — currently **4 IMSIs**
(`001010000000001`–`004`). Add subscribers there to run more.

**Multi-UE attach constraint (sum-bridge).** The co-located bridge *sums* every
UE's uplink, so its add block only produces once **all** UE ZMQ sources have a
peer — i.e. every srsUE must be running. Two consequences:
- Don't space UE starts far apart (no "attach one fully, then start the next") —
  a long gap stalls the summed uplink and **nobody** attaches. The short
  `START_STAGGER` is deliberate.
- Several UEs attaching at once on one cell contend on PRACH; in practice **~2
  UEs/cell** attach reliably here. For more UEs, split them across cells:
  `CELL2_UES` (default `3,4`) routes those UEs through a **second bridge** to a
  second gNB (`GNB2_IP`, ports `GNB2_TX_PORT/RX`). With `NUM_UES=4` +
  `CELL2_UES=3,4` you get 2 UEs/cell on two cells (two slices) — see SETUP §9.5.
  Set `CELL2_UES=""` for single-cell mode.

**Slicing.** UEs are placed on a slice by their 5GC **subscription** S-NSSAI, not
by anything in this container. See `SETUP.md` §9.4 for two slices on one cell.

## Usage

Prereqs: gNB + 5GC, the `ue_n3` and `metrics` networks, and the monitoring stack
(InfluxDB/Grafana) are up — e.g. `./scripts/manage.sh start gnb monitoring`.
Do **not** run `../ue/bridge` at the same time; both claim `10.10.4.237`.

```bash
# Start the container (auto-runs bridge + NUM_UES UEs from .env)
docker compose -f multi_ue/docker-compose.yaml up -d

# Watch attach
docker exec multi_ue ip netns exec ue1 ip addr show tun_srsue
docker exec multi_ue cat /tmp/ue1.log

# Generate traffic on ALL UEs and export to InfluxDB
docker exec multi_ue /srsran/config/run_all_scenarios.sh \
    --voip-client --server-ip 10.45.0.1

# Or one UE (bounded UDP — see the warning about unlimited TCP below)
docker exec multi_ue /srsran/config/run_scenario.sh \
    --video-client --bitrate 1M --server-ip 10.45.0.1 --port 5202 --ue 2

docker compose -f multi_ue/docker-compose.yaml down
```

Set `DEBUG_MODE=true` in `.env` to keep the container idle and drive it by hand
with `/srsran/config/start_all.sh N`.

## Operational notes

- **Supervision / fault tolerance.** `start_all.sh` supervises the processes:
  - The **bridge is critical** — if it dies the script exits and the container
    stops (recreate it; see the restart-order note below).
  - A **UE is independent** — if a srsUE exits (e.g. radio-link failure), it is
    logged and **auto-restarted** up to `MAX_UE_RESTARTS` (default 3). One UE
    failing no longer tears the whole container down, and the other UEs keep
    running. Tune via `RESTART_UES`, `MAX_UE_RESTARTS`, `SUPERVISE_INTERVAL`.
  - **Caveat — mid-stream re-attach is not guaranteed.** A restarted UE
    re-acquires the cell (fresh RACH, new RNTI, good SINR), but completing the
    **NAS re-attach** while the bridge/other UEs keep streaming is unreliable in
    this ZMQ model — the UE can stall at `Attaching...` even though its PHY is
    up. The supervisor's value is preventing the whole-container teardown and
    keeping the surviving UEs alive; for a **guaranteed** re-attach of a dropped
    UE, do the full clean cycle below. Set `RESTART_UES=false` if you prefer a
    failed UE to stay down rather than spin in a half-attached state.

- **Avoid unlimited TCP.** `--file-client` (unbounded `iperf3 -P4`) can saturate
  the real-time ZMQ link and trigger radio-link failure on a UE. Prefer bounded
  rates (`--video-client --bitrate 1M`, `--sd-client`, `--voip-client`). With
  the supervisor a UE that drops will now be restarted, but bounded load is
  still the stable choice for sustained tests.

- **Clean restart order (ZMQ lockstep).** srsRAN ZMQ requires the gNB and UEs to
  start their sample exchange in lockstep. After an **unclean** teardown the
  gNB's ZMQ socket can get stuck (`gnb.log` shows `Completed 0 of 23040
  samples`), and a plain `docker restart` does **not** clear it. Recover with a
  full, ordered cycle:
  ```bash
  docker compose -f multi_ue/docker-compose.yaml down
  ./scripts/manage.sh stop  gnb
  ./scripts/manage.sh start gnb         # wait until gnb.log shows "Waiting for data"
  ./scripts/manage.sh start multi_ue
  ```

- **iperf3 servers live in `open5gs_5gc`.** Traffic targets the UE gateway
  `10.45.0.1`, served by `iperf3 -s` inside the `open5gs_5gc` container. A single
  server handles **one test at a time**, so for concurrent per-UE runs start one
  per port:
  ```bash
  docker exec -d open5gs_5gc iperf3 -s -p 5201
  docker exec -d open5gs_5gc iperf3 -s -p 5202
  ```
  Note: `manage.sh stop gnb` also stops `open5gs_5gc` and kills these servers —
  restart them after any gNB cycle. `run_all_scenarios.sh` works as-is for
  shared-target scenarios like `--latency` (no port contention).

## Files

| File | Role |
|------|------|
| `docker-compose.yaml` / `.env` | one container at `UE_HOST_IP`, env-driven |
| `config/start_all.sh` | start bridge + N UEs, then supervise (restart failed UEs) |
| `config/multi_ue_scenario.py` | co-located single-IP ZMQ bridge |
| `config/start_ue.sh` | start one srsUE in netns `ue<n>` |
| `config/generate_ue_conf.py` | render per-UE srsUE config |
| `config/run_scenario.sh` / `run_all_scenarios.sh` | traffic + InfluxDB export |
| `config/ue_export.py` | iperf3/ping runner → InfluxDB (`ue_traffic`, `ue_latency`) |
