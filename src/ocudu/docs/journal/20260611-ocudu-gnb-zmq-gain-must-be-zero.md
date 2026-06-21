# 20260611 — ocudu gNB rejects ZMQ device gain > 0 dB

- **Date:** 2026-06-11
- **Area:** bring-up
- **Status:** Resolved
- **Components:** ocudu_gnb

> Single-cell ZMQ deployment; new ocudu image `rptestbed/docker-gnb:11062026`.

## Summary
- The ocudu `:11062026` gNB exited on startup with
  `Channel gain must be <= 0.0 dB for ZMQ-device.` → `OCUDU ERROR: Invalid radio configuration.`
- `configs/gnb_zmq.yml` carried `tx_gain: 80 / rx_gain: 40` from the srsRAN config,
  which the ocudu build rejects for the ZMQ device.
- Resolved by setting both gains to 0.

## Context / setup
- `ru_sdr` block in `configs/gnb_zmq.yml`, `device_driver: zmq`.

## Investigation / what was determined
- `docker logs ocudu_gnb` showed the radio init reaching
  `Available radio types: uhd, zmq and realtime_loopback.` then the gain error and
  `Invalid radio configuration` — gNB exits before serving.
- The same gains were tolerated by the interim srsRAN image; the ocudu build adds a
  validation that ZMQ gain must be `<= 0.0 dB`.

## Root cause
- ZMQ is not a real RF front-end, so gain is meaningless; the ocudu build enforces
  `gain <= 0.0 dB` for the `zmq` device and aborts on the inherited `tx_gain: 80` /
  `rx_gain: 40`.

## Resolution / workaround
- Set `tx_gain: 0` and `rx_gain: 0` in `configs/gnb_zmq.yml` (with a comment noting the
  ocudu ZMQ constraint).

## Lessons / gotchas
- Configs migrated from srsRAN can carry RF values the stricter ocudu build rejects;
  read the exact `OCUDU ERROR` line — it names the offending parameter.

## References
- `configs/gnb_zmq.yml`
