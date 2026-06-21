# 20260610 — ZMQ lockstep: UE re-attach needs a gNB restart

- **Date:** 2026-06-10
- **Area:** traffic / stability
- **Status:** Mitigated (operational gotcha)
- **Components:** ocudu_gnb, multi_ue

> Single-cell ZMQ deployment.

## Summary
- Restarting only the UE container (while the gNB kept running) left the UE stuck at
  `Attaching...` with no RACH; the gNB's ZMQ stream had desynced.
- ZMQ has no real radio — the gNB and UE exchange samples in lockstep — so the bridge/UE
  cannot cleanly re-join a gNB whose ZMQ socket is mid-stream.
- Mitigation: a clean, ordered cycle (stop UE → restart gNB → start UE).

## Context / setup
- `multi_ue` runs a co-located ZMQ bridge + srsUE. The gNB drives the sample clock and,
  when idle, logs `Waiting for data` / `Completed 0 of 23040 samples`.

## Investigation / what was determined
- `docker compose -f multi_ue/docker-compose.yaml restart` (UE only) → `ue1.log` stuck
  at `Attaching...`, no `Random Access Transmission`; AMF shows no new registration.
- Doing the ordered cycle instead — stop UE, `docker restart ocudu_gnb` (wait for
  `Waiting for data`), then start UE — produced a clean RACH → RRC → registration.

## Root cause
- srsRAN/ocudu ZMQ requires the gNB and UE to begin their sample exchange in lockstep.
  After the UE/bridge restarts under a still-running gNB, the gNB's ZMQ socket is left
  in a state the fresh bridge can't re-sync to. Not a fault — inherent to the ZMQ RF
  model (documented in `multi_ue/README.md`).

## Resolution / workaround
- Always re-attach with the ordered cycle:
  ```
  docker compose -f multi_ue/docker-compose.yaml down
  docker restart ocudu_gnb     # wait for "Waiting for data" in /tmp/gnb.log
  docker compose -f multi_ue/docker-compose.yaml up -d
  ```

## Lessons / gotchas
- Don't `docker restart` the UE alone in a ZMQ deployment; cycle the gNB too.
- A UE sitting at `Attaching...` with no RACH (vs. RACH-then-reject) points at the PHY/
  ZMQ sample path, not the core.

## References
- `multi_ue/README.md`
