# 20260611 — Entrypoint default subscriber written to the wrong Mongo DB

- **Date:** 2026-06-11
- **Area:** bring-up
- **Status:** Resolved
- **Components:** open5gs_5gc

> Single-cell ZMQ deployment; introduced while converting the entrypoint to
> `open5gs-dbctl` (see [Cannot find SUPI](./20260610-ue-registration-cannot-find-supi.md)).

## Summary
- The Open5GS entrypoint logged a successful dbctl insert of the default subscriber, but
  it never appeared in the `open5gs` database — it went to Mongo's default `test` DB.
- The entrypoint passed `--db_uri="mongodb://127.0.0.1"` with no database path, so dbctl
  used pymongo's default db (`test`) instead of `open5gs`.
- Resolved by putting `/open5gs` in the URI.

## Context / setup
- New `docker-5gc:11062026` entrypoint provisions the default `SUBSCRIBER_DB` via
  `open5gs-dbctl`. The multi_ue test UE is added separately by `scripts/add_user.sh`
  (which calls dbctl with no `--db_uri`, so it correctly hit `open5gs`).

## Investigation / what was determined
- Entrypoint log: `insertedId: ObjectId(...)` for `001010123456780` — insert "succeeded".
- `mongosh open5gs --eval 'db.subscribers.find()'` → only the multi_ue UE
  (`001010000000001`), **not** the default subscriber.
- Enumerated all databases:
  `db.getMongo().getDBNames().forEach(... subscribers.countDocuments ...)` →
  `open5gs: 001010000000001` and `test: 001010123456780`. The default sub landed in `test`.

## Root cause
- `open5gs-dbctl --db_uri="mongodb://127.0.0.1"` has no DB in the URI path; dbctl/pymongo
  then default to the `test` database. (Calling dbctl with no `--db_uri` uses its built-in
  default which resolves to `open5gs`, which is why `add_user.sh` worked.)

## Resolution / workaround
- Entrypoint now uses `--db_uri="mongodb://${MONGODB_IP}/open5gs"` for the remove/add
  calls, so the default subscriber lands in `open5gs`.
- Note: didn't block the e2e test (the test UE was provisioned correctly via
  `add_user.sh`), but the entrypoint's own default-subscriber seeding was broken.
- Requires a 5gc image rebuild to take effect (entrypoint is baked into the image).

## Lessons / gotchas
- Always include the database in the Mongo URI (`mongodb://host/open5gs`); a "successful"
  insert with an `ObjectId` says nothing about *which* DB it hit.
- Verify provisioning by reading back from the `open5gs` DB, and enumerate all DBs when an
  insert "succeeds" but isn't found.

## References
- `docker/open5gs/open5gs_entrypoint.sh`, `scripts/add_user.sh`
