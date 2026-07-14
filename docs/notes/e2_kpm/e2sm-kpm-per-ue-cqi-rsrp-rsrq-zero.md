# 20260606 — E2SM-KPM reports CQI/RSRP/RSRQ = 0 for all UEs except the first

Date: 2026-06-06

> Paths below are relative to the repo root `oran-testbed/`.
> Code line numbers refer to the srsRAN source vendored under `ocudu/`.

## Summary
- While extracting per-UE KPM metrics over E2 with the O-RAN SC RIC `kpm_mon` xApp
  (report style 4, all supported metrics), **UE 1 reported `CQI = 0`, `RSRP = 0`,
  `RSRQ = 0`** while UE 0 reported `CQI = 15`, `RSRP = 6`.
- Throughput / PRB / delay / volume metrics were correct for **both** UEs.
- Root cause: **a srsRAN E2SM-KPM measurement-provider bug** — the CQI/RSRP/RSRQ
  getters hardcode `last_ue_metrics[0]` and emit a single record, so only the
  UE at index 0 ever gets a real value. UE 1 is healthy; the radio is fine.
- Secondary finding: **`RSRP` and `RSRQ` are not real RSRP/RSRQ** in this build —
  both getters return `(int)pusch_snr_db`.

## Context / setup
- ZMQ deployment: `srsran_gnb` (single 20 MHz cell, band 3), two UEs (`ue1`, `ue2`)
  over the ZMQ bridge, Open5GS 5GC, and the oran-sc-ric RIC.
- Metrics stack: gNB metrics → telegraf (`ws_adapter.py`) → InfluxDB 3 → Grafana.
- The xApp was wired to push its KPM indications into the same InfluxDB 3 (db `srsran`,
  measurement `kpm`) via a new best-effort writer, so xApp values could be compared
  on the same timeline as the gNB's native per-UE metrics (measurement `ue`).
  - `ric/xApps/python/lib/influx_writer.py` — line-protocol writer.
  - `ric/xApps/python/kpm_mon_xapp.py` — writer hooked into `my_subscription_callback`.
  - `ric/docker-compose.yml` — `python_xapp_runner` attached to the `metrics` network.
  - `srsRAN_Project/docker/grafana/dashboards/xapp_kpm.json` — dashboard for the `kpm` measurement.

## How it was determined

### 1. Observed the symptom (style-4 capture)
Running the KPM xApp with report style 4 (per-UE) and the full supported metric set
returned, for every indication:
- `UE_id 0`: `CQI=15`, `RSRP=6`, `RSRQ=6` (plus correct thp/PRB/delay)
- `UE_id 1`: `CQI=0`,  `RSRP=0`, `RSRQ=0` (but correct thp/PRB/delay)

Command:
```
docker compose exec python_xapp_runner ./kpm_mon_xapp.py --kpm_report_style=4 \
  --metrics=DRB.UEThpDl,DRB.UEThpUl,RRU.PrbUsedDl,RRU.PrbUsedUl,RRU.PrbTotDl,RRU.PrbTotUl,\
RRU.PrbAvailDl,RRU.PrbAvailUl,DRB.RlcSduTransmittedVolumeDL,DRB.RlcSduTransmittedVolumeUL,\
DRB.RlcSduDelayDl,DRB.AirIfDelayUl,DRB.RlcDelayUl,DRB.RlcPacketDropRateDl,CQI,RSRP,RSRQ
```

### 2. Cross-checked against the gNB's own per-UE metrics (ground truth)
The gNB's native metrics (telegraf `ue` measurement in InfluxDB) showed **both** UEs
healthy over the same 20 s window:

| UE | gNB `ue` meas (ground truth) | KPM `kpm` meas (xApp/E2) |
|----|------------------------------|--------------------------|
| 0  | CQI **15**, SNR 6.0 dB, ~8.6 Mbps | CQI **15**, RSRP 6 |
| 1  | CQI **15**, SNR 5.3 dB, ~9.0 Mbps | CQI **0**,  RSRP **0** |

Queries used:
```
-- KPM (xApp) view
SELECT ue_id, max("CQI") cqi, max("RSRP") rsrp, avg("DRB_UEThpDl") dl_thp
FROM kpm WHERE time > now() - INTERVAL '20 seconds' GROUP BY ue_id ORDER BY ue_id;

-- gNB (native) view — ground truth
SELECT ue, max(cqi) cqi, avg(pusch_snr_db) snr, avg(dl_brate) dl_brate
FROM ue  WHERE time > now() - INTERVAL '20 seconds' GROUP BY ue ORDER BY ue;
```
Conclusion from this step: UE 1's link is fine; the `0` originates in the E2SM-KPM
metric path, not the radio.

### 3. Located the defect in the srsRAN E2SM-KPM measurement provider
All three radio-quality getters take the requested UE list but ignore it for
indexing — they read `last_ue_metrics[0]` and push exactly one record:

File: `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp`
- `get_cqi(...)` — definition at **L334**; hardcoded index `last_ue_metrics[0]` at **L343**.
- `get_rsrp(...)` — definition at **L355**; hardcoded index at **L364**; value is
  `(int)ue_metrics.pusch_snr_db` at **L367**.
- `get_rsrq(...)` — definition at **L374**; hardcoded index at **L383**; value is
  `(int)ue_metrics.pusch_snr_db` at **L386**.

Because the getter emits a single item, the report-service maps it to the first UE
in the subscription; subsequent UEs receive the default `0`.

### 4. Confirmed the contrast with a correctly-implemented getter
The throughput/PRB/delay getters build a per-UE map and emit one record **per UE**,
which is why those columns are correct for both UEs:

File: `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp`
- `get_drb_dl_mean_throughput(...)` — definition at **L720**; per-UE loop
  `for (auto& ue : ue_aggr_rlc_metrics)` at **L736**.
- `get_drb_ul_mean_throughput(...)` — definition at **L793** (same pattern).

### 5. Metric registration (for completeness)
The three metrics are registered with `UNKNOWN_LEVEL` (not standard 3GPP levels),
in the DU provider constructor:

File: `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp`
- `CQI`  registration at **L34**
- `RSRP` registration at **L36**
- `RSRQ` registration at **L38**

## Root cause
`e2sm_kpm_du_meas_provider_impl::get_cqi/get_rsrp/get_rsrq` do not iterate over the
requested UEs; they read `last_ue_metrics[0]` and push a single measurement record.
For any per-UE report style (2/4/5), only the index-0 UE receives a real value; all
other UEs default to `0`. The defect is in srsRAN, not in the deployment, the RIC,
the xApp, or UE 1's radio link.

Additionally, `RSRP` and `RSRQ` are mislabeled: both return `(int)pusch_snr_db`
(L367, L386), i.e. PUSCH SNR in dB, not RSRP/RSRQ. (This is why UE 0's "RSRP" read
`6`, matching its ~6 dB SNR.)

## Impact
- Per-UE radio quality over E2 is unreliable in this build: only the first UE's CQI
  is meaningful; RSRP/RSRQ are SNR for any UE and `0` for all but the first.
- Any xApp control loop that consumes CQI/RSRP/RSRQ per UE over E2 must not trust
  these values for UEs beyond index 0.
- Throughput, PRB usage, RLC volume, and the delay metrics are per-UE correct.

## Resolution / recommendations
1. **For observation (no rebuild):** source per-UE radio quality from the gNB's
   native `ue` measurement (correct `cqi`, `pusch_snr_db`, `dl_ri`, `dl_mcs`, …),
   already in InfluxDB via telegraf. Repoint the dashboard's Radio Quality panels
   from `kpm` to `ue`.
2. **For correct CQI over E2 (requires rebuild):** patch the three getters in
   `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp` (L334–L392)
   to iterate over the requested UEs and emit one record per UE — mirroring
   `get_drb_dl_mean_throughput` (L720/L736) — then `docker compose build gnb`.
   Also rename/fix RSRP/RSRQ (L367, L386) so they no longer return PUSCH SNR.

## References (code)
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:34` — CQI registration
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:36` — RSRP registration
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:38` — RSRQ registration
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:334` — `get_cqi` definition
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:343` — `last_ue_metrics[0]` (CQI)
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:355` — `get_rsrp` definition
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:364` — `last_ue_metrics[0]` (RSRP)
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:367` — RSRP = `(int)pusch_snr_db`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:374` — `get_rsrq` definition
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:383` — `last_ue_metrics[0]` (RSRQ)
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:386` — RSRQ = `(int)pusch_snr_db`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:720` — `get_drb_dl_mean_throughput` (correct per-UE pattern)
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:736` — per-UE loop `for (auto& ue : ue_aggr_rlc_metrics)`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp:793` — `get_drb_ul_mean_throughput`

## References (deployment artifacts)
- `ric/xApps/python/lib/influx_writer.py` — xApp → InfluxDB 3 line-protocol writer.
- `ric/xApps/python/kpm_mon_xapp.py` — writer hooked into the KPM indication callback.
- `ric/docker-compose.yml` — `python_xapp_runner` attached to the `metrics` network + `INFLUX_*` env.
- `src/ocudu/docker/grafana/dashboards/xapp_kpm.json` — Grafana dashboard (measurement `kpm`).
- InfluxDB: db `srsran`, measurement `kpm` (xApp/E2 view) vs `ue` (gNB native view).
