# 20260610 — UE registration reject: "Cannot find SUPI in DB"

- **Date:** 2026-06-10
- **Area:** RAN / slicing
- **Status:** Resolved
- **Components:** open5gs_5gc, multi_ue

> Single-cell ZMQ deployment. UE IMSI `001010000000001`, K
> `465B5CE8B199B49FAA5F0A2EE238A6BC`, OPc `E8ED289DEBA952E4283B54E88E6183CA`
> (from `multi_ue/config/generate_ue_conf.py`).

## Summary
- The UE reached RRC Connected but was immediately released; AMF logged
  `Cannot find SUPI in DB` / `No AccessAndMobilitySubscriptionData` → Registration
  reject [7]. No PDU session, no UE IP.
- The subscriber *was* present in Mongo, but the doc produced by the image's
  `add_users.py` was rejected by this Open5GS release's UDR.
- Resolved by provisioning with the canonical `open5gs-dbctl`; `add_users.py` removed.

## Context / setup
- Open5GS auto-provisions only its default subscriber (`001010123456780`); the multi_ue
  UE must be added separately. Provisioning was done via `scripts/open5gs_add_ue.sh`
  (which wrapped `add_users.py`).

## Investigation / what was determined
- `docker logs open5gs_5gc` →
  `[udr] Cannot find SUPI in DB` and `[udm] No AccessAndMobilitySubscriptionData`
  for `imsi-001010000000001`, then `[amf] Registration reject [7]`.
- `mongosh open5gs --eval 'db.subscribers.find({imsi:"001010000000001"})'` → the doc
  *was* present, with the correct imsi/key/opc and `db_uri = mongodb://127.0.0.1/open5gs`.
- Re-provisioned the same IMSI with `open5gs-dbctl add` → registration completed and
  PDU session came up. So the difference was the document content, not its presence.
- Diffed an `add_users.py` doc against a `dbctl` doc: `add_users.py` omitted several
  fields the dbctl/WebUI doc carries (e.g. `security.sqn`, `operator_determined_barring`,
  per-slice `_id`). Adding only `security.sqn` was **not** sufficient — auth advanced
  (sqn incremented) but the later AccessAndMobilitySubscriptionData fetch still failed.

## Root cause
- `add_users.py` (via the bundled `Open5GS.py` helper) produced subscriber documents
  that this Open5GS 2.7.6 UDR does not accept for AccessAndMobilitySubscriptionData, so
  the AM-data lookup returns not-found ("Cannot find SUPI in DB") and the AMF rejects
  registration. `open5gs-dbctl` produces the canonical, accepted document.

## Resolution / workaround
- Provision via `open5gs-dbctl` exclusively:
  - Removed `docker/open5gs/add_users.py` (and dropped it from the Dockerfile COPY).
  - The entrypoint now seeds the default subscriber via `open5gs-dbctl`.
  - Removed `scripts/open5gs_add_ue.sh`; added `scripts/add_user.sh`, which
    `docker exec`s `open5gs-dbctl` (defaults to multi_ue UE #1).

## Lessons / gotchas
- "Cannot find SUPI in DB" can fire even when the IMSI *is* in Mongo — it means the
  subscriber **document** is malformed/incomplete for the UDR, not that it is absent.
- `JSON.stringify` renders a Mongo `ObjectId` as a bare hex string — don't mistake that
  for a string `_id` when diffing docs (an early wrong turn here).
- Prefer the canonical `open5gs-dbctl` for provisioning over hand-rolled inserters.

## References
- `docker/open5gs/open5gs_entrypoint.sh`, `scripts/add_user.sh`
- Related: [default subscriber written to wrong Mongo DB](./20260611-open5gs-default-subscriber-wrong-mongo-db.md)
