# Engineering journal — cudu-deployment (single-cell ZMQ)

Per-issue write-ups from bringing the OCUDU single-cell ZMQ stack up end to end
(5GC + gNB + 1 UE → ping google.com) on the testbed. Each entry follows
[TEMPLATE.md](./TEMPLATE.md): symptom → investigation → root cause → fix.

Newest first:

| Date | Status | Entry |
|------|--------|-------|
| 2026-06-11 | Mitigated (rebuild) | [gNB crashes with SIGILL once PHY runs (march mismatch)](./20260611-gnb-sigill-march-native.md) |
| 2026-06-11 | Resolved | [Entrypoint default subscriber written to the wrong Mongo DB](./20260611-open5gs-default-subscriber-wrong-mongo-db.md) |
| 2026-06-11 | Resolved | [ocudu gNB rejects ZMQ device gain > 0 dB](./20260611-ocudu-gnb-zmq-gain-must-be-zero.md) |
| 2026-06-10 | Mitigated (gotcha) | [ZMQ lockstep: UE re-attach needs a gNB restart](./20260610-zmq-lockstep-ue-reattach-needs-gnb-restart.md) |
| 2026-06-10 | Resolved | [UE attaches but no internet: UPF MASQUERADE missing](./20260610-ue-no-internet-upf-masquerade-missing.md) |
| 2026-06-10 | Resolved | [UE registration reject: "Cannot find SUPI in DB"](./20260610-ue-registration-cannot-find-supi.md) |
| 2026-06-10 | Resolved | [gNB config parse error: amf addr vs addrs schema](./20260610-gnb-amf-config-schema-singular-vs-plural.md) |
| 2026-06-10 | Resolved | [gNB image fails to start: libmkl_rt.so.3 not found](./20260610-gnb-image-missing-libmkl-rt.md) |

For the operational procedure (deploy → provision → attach → ping), see the
[ZMQ e2e runbook](../zmq-e2e-runbook.md).

## Status at a glance
- End-to-end ZMQ ping **works** once the gNB image is rebuilt with a testbed-compatible
  `MARCH` (the one open blocker — see the SIGILL entry). All other issues are fixed in
  the repo; the open5gs entrypoint fixes (#4 dbctl provisioning, #5 MASQUERADE, the
  `/open5gs` db_uri) take effect on the next `docker-5gc` image rebuild.
- See also the top-level [radr_changelog.md](../../radr_changelog.md).
