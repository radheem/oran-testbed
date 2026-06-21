# 20260610 — gNB config parse error: amf addr vs addrs schema

- **Date:** 2026-06-10
- **Area:** bring-up
- **Status:** Resolved
- **Components:** ocudu_gnb

> Single-cell ZMQ deployment; gNB config `configs/gnb_zmq.yml` +
> `configs/gnb_zmq_compose_config.yml`.

## Summary
- The gNB exited on startup with `INI was not able to parse cu_cp.amf.addrs`.
- The `cu_cp.amf` address keys differ between the srsRAN and ocudu forks: srsRAN uses
  singular `addr`/`bind_addr`, ocudu uses plural `addrs`/`bind_addrs`.
- Resolved by matching the config to whichever gNB binary is being run.

## Context / setup
- `configs/gnb_zmq.yml` and the compose overlay `configs/gnb_zmq_compose_config.yml`
  both set `cu_cp.amf` addresses (and the gNB merges them with two `-c` flags).

## Investigation / what was determined
- `docker logs ocudu_gnb` → `INI was not able to parse cu_cp.amf.addrs` (when running
  a srsRAN build against a plural-schema config), or the symmetric failure with
  `addr` against the ocudu build.
- Cross-checked the ocudu in-repo example `configs/amf.yml` /
  `configs/gnb_rf_b200_tdd_n78_20mhz.yml`, which use plural `addrs`/`bind_addrs`.

## Root cause
- Two different gNB binaries were in play during bring-up:
  - The interim `rptestbed/gnb:20260610-dpdk` is a **srsRAN** build → expects
    **singular** `addr`/`bind_addr`.
  - The `rptestbed/docker-gnb:11062026` is the **ocudu** build → expects **plural**
    `addrs`/`bind_addrs`.
  A config written for one is rejected by the other.

## Resolution / workaround
- Set the `cu_cp.amf` keys in both `configs/gnb_zmq.yml` and
  `configs/gnb_zmq_compose_config.yml` to match the binary in use. Final state for the
  ocudu `:11062026` image: **plural** `addrs` / `bind_addrs`.

## Lessons / gotchas
- The gNB only reports the *first* offending key; fix it and re-run to surface the next.
- When swapping the gNB image between forks, re-check the config schema — the parser is
  strict and a single wrong key aborts startup.
- Real logs go to `log.filename` (`/tmp/gnb.log`); the parse error prints to stdout
  (`docker logs`) before file logging is set up — and a stale stdout error can linger
  after a `docker start`, so confirm against `/tmp/gnb.log` / process state.

## References
- `configs/gnb_zmq.yml`, `configs/gnb_zmq_compose_config.yml`, `configs/amf.yml`
