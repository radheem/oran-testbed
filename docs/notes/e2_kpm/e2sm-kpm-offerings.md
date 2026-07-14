# 20260714 — E2SM-KPM surface offered by `src/ocudu/lib/e2/e2sm/e2sm_kpm`

Date: 2026-07-14

> Paths below are relative to the repo root `oran-testbed/`.

## Summary
- This tree implements an **E2SM-KPM monitor** for the DU/CU side of the stack.
- It advertises **report styles 1 through 5** when the measurement provider exposes at least one supported metric for the relevant level.
- It supports **periodic KPM reporting** and **ASN.1 packing/unpacking** of KPM action definitions, event triggers, and indication messages.
- **KPM control is not supported** in this slice.

## What it offers
### Report styles
The implementation maps the KPM action formats to the standard report styles:
- **Style 1**: E2 node measurement
- **Style 2**: single-UE measurement
- **Style 3**: condition-based UE measurement
- **Style 4**: common condition-based UE measurement
- **Style 5**: multi-UE measurement

That mapping is implemented in `e2sm_kpm_impl.cpp`, while the RAN function advertisement is built in `e2sm_kpm_asn1_packer.cpp` from whatever metrics the provider reports as supported.

### Measurement catalog
The actual offered measurements are small and split by provider:
- **CU-CP metrics**: RRC and UE context establishment counters, plus mean/max RRC connection count.
- **CU-UP metrics**: PDCP reordering delay and packet success rate over gNB-Uu.

The provider currently registers only the following metric names:
- `RRC.ConnEstabAtt`
- `RRC.ConnEstabSucc`
- `RRC.ConnEstabFailCause.NetworkReject`
- `UECNTX.ConnEstabAtt`
- `UECNTX.ConnEstabSucc`
- `RRC.ReEstabAtt`
- `RRC.ReEstabSuccWithUeContext`
- `RRC.ConnMean`
- `RRC.ConnMax`
- `DRB.PdcpReordDelayUl`
- `DRB.PacketSuccessRateUlgNBUu`

## Behavior limits
- Most supported metrics are **NO_LABEL-only** in practice.
- The provider admission checks are permissive in some places, but the runtime getters still short-circuit on labels and supported metric names.
- `is_cell_supported`, `is_ue_supported`, and `is_test_cond_supported` are currently placeholders that return `true`, so support is mostly gated by the metric name and report style.
- The KPM path is read-only: there is no corresponding control-service implementation.

## Notes for users of this tree
- If you need KPM for per-UE radio-quality metrics such as CQI/RSRP/RSRQ, this tree does **not** expose them.
- If you need a quick sanity check of what is actually advertised over E2, inspect `e2sm_kpm_asn1_packer.cpp` and the `supported_metrics` tables in `e2sm_kpm_cu_meas_provider_impl.cpp`.

## References
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_asn1_packer.cpp`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_impl.cpp`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_cu_meas_provider_impl.cpp`
- `src/ocudu/lib/e2/e2sm/e2sm_kpm/e2sm_kpm_report_service_impl.cpp`
