# E2SM-KPM surface offered by `src/ocudu/lib/e2/e2sm/e2sm_kpm`

Date: 2026-07-14 (updated 2026-07-21)

> Paths below are relative to the repo root `oran-testbed/`.

## Summary
- This tree implements an **E2SM-KPM monitor** for the DU/CU side of the stack.
- It advertises **report styles 1 through 5** when the measurement provider exposes at least one supported metric for the relevant level.
- It supports **periodic KPM reporting** and **ASN.1 packing/unpacking** of KPM action definitions, event triggers, and indication messages.
- **KPM control is not supported** in this slice.

## Report styles

| Style | Name | Scope | Supported metric levels |
|-------|------|-------|------------------------|
| 1 | E2 node measurement | Cell / E2-node | All CU-CP, all CU-UP, all DU |
| 2 | Single-UE measurement | Per UE | DU UE-level only |
| 3 | Condition-based UE measurement | Per UE (conditional) | DU UE-level only |
| 4 | Common condition-based UE measurement | Group of UEs | DU UE-level only |
| 5 | Multi-UE measurement | Group of UEs | DU UE-level only |

Style 1 is the broadest — it can carry metrics from all three providers (CU-CP, CU-UP, DU) at the E2-node level.
Styles 2–5 carry only DU-level UE-scoped metrics.

Implementation: `e2sm_kpm_impl.cpp` maps action formats to report styles; RAN function advertisement is built in `e2sm_kpm_asn1_packer.cpp` from whatever metrics the provider reports as supported.

## Measurement catalog

The actual offered measurements are split across three measurement-provider implementations. The provider currently registers **29 metric names** in total:

### DU provider (`e2sm_kpm_du_meas_provider_impl.cpp`) — 18 metrics

#### Radio-resource utilization (RRU)

| Metric | Level | Data type | Source |
|--------|-------|-----------|--------|
| `RRU.PrbTotDl` | E2_NODE, UE | integer | DL PRB usage % |
| `RRU.PrbTotUl` | E2_NODE, UE | integer | UL PRB usage % |
| `RRU.PrbUsedDl` | E2_NODE, UE | integer | mean PDSCH PRBs per slot |
| `RRU.PrbAvailDl` | E2_NODE, UE | integer | `nof_cell_prbs - mean_dl_prbs_used` |
| `RRU.PrbUsedUl` | E2_NODE, UE | integer | mean PUSCH PRBs per slot |
| `RRU.PrbAvailUl` | E2_NODE, UE | integer | `nof_cell_prbs - mean_ul_prbs_used` |

#### RLC data radio bearer metrics

| Metric | Level | Data type | Source |
|--------|-------|-----------|--------|
| `DRB.RlcSduDelayDl` | ALL_LEVELS | real (0.1 ms) | RLC TX SDU latency |
| `DRB.UEThpDl` | E2_NODE, UE | real (kbps) | RLC TX throughput (per UE) |
| `DRB.UEThpUl` | E2_NODE, UE | real (kbps) | RLC RX throughput (per UE) |
| `DRB.RlcPacketDropRateDl` | ALL_LEVELS | integer | RLC TX drop+discard ratio × 100 |
| `DRB.RlcSduTransmittedVolumeDL` | ALL_LEVELS | integer (kbit) | RLC TX SDU bytes × 8 / 1000 |
| `DRB.RlcSduTransmittedVolumeUL` | ALL_LEVELS | integer (kbit) | RLC RX SDU bytes × 8 / 1000 |
| `DRB.AirIfDelayUl` | ALL_LEVELS | real (0.1 ms) | `avg_crc_delay_ms` from scheduler |
| `DRB.RlcDelayUl` | ALL_LEVELS | real (0.1 ms) | RLC RX SDU latency |

#### RACH

| Metric | Level | Data type | Source |
|--------|-------|-----------|--------|
| `RACH.PreambleDedCell` | E2_NODE | integer | `nof_ded_cell_preambles` |

#### Radio-quality (per-UE, DU)

| Metric | Level | Data type | Source | Known issue |
|--------|-------|-----------|--------|-------------|
| `CQI` | UNKNOWN_LEVEL | integer | `last_ue_metrics[0].cqi_stats` | Always reports UE 0 |
| `RSRP` | UNKNOWN_LEVEL | integer | `last_ue_metrics[0].pusch_snr_db` | Reports PUSCH SNR, not RSRP |
| `RSRQ` | UNKNOWN_LEVEL | integer | `last_ue_metrics[0].pusch_snr_db` | Reports PUSCH SNR, not RSRQ |

### CU-CP provider (`e2sm_kpm_cu_meas_provider_impl.cpp`) — 9 metrics

All at `E2_NODE` level unless noted.

| Metric | Level | Data type | Source |
|--------|-------|-----------|--------|
| `RRC.ConnEstabAtt` | E2_NODE | integer | DU-level attempted RRC connections |
| `RRC.ConnEstabSucc` | E2_NODE | integer | DU-level successful RRC connections |
| `RRC.ConnEstabFailCause.NetworkReject` | E2_NODE | integer | Network-reject failures |
| `UECNTX.ConnEstabAtt` | E2_NODE | integer | NGAP UE context establishment attempts |
| `UECNTX.ConnEstabSucc` | E2_NODE | integer | NGAP UE context establishment successes |
| `RRC.ReEstabAtt` | E2_NODE | integer | RRC re-establishment attempts |
| `RRC.ReEstabSuccWithUeContext` | E2_NODE | integer | RRC re-establishment successes (with UE context) |
| `RRC.ConnMean` | E2_NODE | integer | Mean number of RRC connections |
| `RRC.ConnMax` | E2_NODE | integer | Max number of RRC connections |

### CU-UP provider (`e2sm_kpm_cu_meas_provider_impl.cpp`) — 2 metrics

All at `E2_NODE` level.

| Metric | Level | Data type | Source |
|--------|-------|-----------|--------|
| `DRB.PdcpReordDelayUl` | E2_NODE | real (0.1 ms) | PDCP re-ordering delay |
| `DRB.PacketSuccessRateUlgNBUu` | E2_NODE | integer | UL PDCP SDU success rate (SDUs/PDUs × 100) |

### Full metric inventory with spec coverage

`e2sm_kpm_metric_defs.h` contains the **full 288 metrics** defined in 3GPP TS 28.552 and O-RAN E2SM-KPM. The table below annotates every category with implementation status.

| Category | Defined (spec) | Implemented (this tree) | % | Details |
|----------|---------------|------------------------|---|---------|
| RRC Connection | 18 | 9 | 50% | `ConnEstabAtt/Succ/FailCause.NetworkReject/ReEstabAtt/ReEstabSuccWithUeContext/ConnMean/ConnMax` |
| UECNTX | 4 | 2 | 50% | `ConnEstabAtt/Succ` |
| RRU PRB | 16 | 6 | 38% | `PrbTotDl/Ul, PrbUsedDl/Ul, PrbAvailDl/Ul` |
| DRB Throughput | 7 | 2 | 29% | `UEThpDl/Ul` |
| DRB Delay | 20 | 4 | 20% | `AirIfDelayUl, RlcDelayUl, PdcpReordDelayUl, RlcSduDelayDl` |
| DRB Volume | 22 | 2 | 9% | `RlcSduTransmittedVolumeDL/UL` |
| DRB Loss / Success | 10 | 2 | 20% | `RlcPacketDropRateDl, PacketSuccessRateUlgNBUu` |
| DRB Setup / Release | 13 | 0 | 0% | `EstabAtt, EstabSucc, RelActNbr, SessionTime`, etc. |
| CQI / MCS / L1 Radio | 20 | 3 | 15% | `CQI, RSRP, RSRQ` (all with known reporting bugs) |
| Transport Block | 10 | 0 | 0% | `TotNbrDl, ErrTotNbrDl`, etc. |
| QoS Flow | 13 | 0 | 0% | `EstabAttNbr, EstabSuccNbr, EstabFailNbr`, etc. |
| Mobility / HO | 69 | 0 | 0% | All inter/intra-gNB, conditional, DAPS, split-gNB HO metrics |
| SM (PDU Session) | 5 | 0 | 0% | `PDUSessionSetup[Succ/Fail]`, `Mean/MaxPDUSessionSetupReq` |
| RACH | 8 | 1 | 13% | `PreambleDedCell` |
| Beam / MIMO / Carrier | 20 | 0 | 0% | CQI distributions, MIMO layer counts, TM power |
| GTP / N3 Network Delay | 4 | 0 | 0% | `DelayDlPsaUpfNgranMean`, packet loss on N3 |
| Paging | 6 | 0 | 0% | Received/Discarded counts (CN/RAN initiated) |
| 5QI-1 Call Duration | 4 | 0 | 0% | Norm/Abnorm call duration (average, distribution) |
| MRO HO Failures | 13 | 0 | 0% | TooEarly/TooLate/ToWrongCell/Uncessary/PingPong |
| PEE (Power/Energy) | 10 | 0 | 0% | Avg/Min/Max Power, Temperature, Voltage, Current, Humidity |
| Virtualization | 3 | 0 | 0% | VCPU / VMem / VDisk usage mean |
| **Total** | **~288** | **29** | **~10%** | |

### Metric names at a glance (29 implemented)

```text
// DU-level (18)
CQI
RSRP
RSRQ
RRU.PrbAvailDl          RRU.PrbAvailUl          RRU.PrbUsedDl
RRU.PrbUsedUl           RRU.PrbTotDl            RRU.PrbTotUl
DRB.RlcSduDelayDl       DRB.UEThpDl             DRB.UEThpUl
DRB.RlcPacketDropRateDl DRB.RlcSduTransmittedVolumeDL
DRB.RlcSduTransmittedVolumeUL
DRB.AirIfDelayUl        DRB.RlcDelayUl
RACH.PreambleDedCell

// CU-CP-level (9)
RRC.ConnEstabAtt        RRC.ConnEstabSucc       RRC.ConnEstabFailCause.NetworkReject
UECNTX.ConnEstabAtt     UECNTX.ConnEstabSucc    RRC.ReEstabAtt
RRC.ReEstabSuccWithUeContext
RRC.ConnMean            RRC.ConnMax

// CU-UP-level (2)
DRB.PdcpReordDelayUl    DRB.PacketSuccessRateUlgNBUu
```

## Behavior limits
- Most supported metrics are **NO_LABEL-only** in practice.
- The provider admission checks are permissive in some places, but the runtime getters still short-circuit on labels and supported metric names.
- `is_cell_supported`, `is_ue_supported`, and `is_test_cond_supported` are currently placeholders that return `true`, so support is mostly gated by the metric name and report style.
- The KPM path is read-only: there is no corresponding control-service implementation.
- `CQI`, `RSRP`, and `RSRQ` are currently hardcoded to UE index 0 (bug documented in `e2sm-kpm-per-ue-cqi-rsrp-rsrq-zero.md`).

## xApp usage

The KPM xApp (`ric/xApps/python/kpm_mon_xapp.py`) accepts metrics as a comma-separated string via the `--metrics` CLI flag:

```bash
docker exec -t python_xapp_runner sh -c \
  'python3 ./kpm_mon_xapp.py --e2_node_id <ID> --kpm_report_style 1 \
   --metrics "CQI,RSRP,RSRQ,RRU.PrbAvailDl,RRU.PrbAvailUl,RRU.PrbUsedDl,RRU.PrbUsedUl,RRU.PrbTotDl,RRU.PrbTotUl,DRB.RlcSduDelayDl,DRB.UEThpDl,DRB.UEThpUl,DRB.RlcPacketDropRateDl,DRB.RlcSduTransmittedVolumeDL,DRB.RlcSduTransmittedVolumeUL,DRB.AirIfDelayUl,DRB.RlcDelayUl,RACH.PreambleDedCell,RRC.ConnEstabAtt,RRC.ConnEstabSucc,RRC.ConnEstabFailCause.NetworkReject,UECNTX.ConnEstabAtt,UECNTX.ConnEstabSucc,RRC.ReEstabAtt,RRC.ReEstabSuccWithUeContext,RRC.ConnMean,RRC.ConnMax,DRB.PdcpReordDelayUl,DRB.PacketSuccessRateUlgNBUu"'
```

Style 1 can receive metrics from all three providers. Styles 2–5 only produce DU-level UE metrics.

## References
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_asn1_packer.cpp`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_impl.cpp`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_cu_meas_provider_impl.cpp`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_cu_meas_provider_impl.h`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.cpp`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_du_meas_provider_impl.h`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_report_service_impl.cpp`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_metric_defs.h`
- `ric/xApps/python/kpm_mon_xapp.py`
- `docs/notes/e2_kpm/e2sm-kpm-per-ue-cqi-rsrp-rsrq-zero.md`
