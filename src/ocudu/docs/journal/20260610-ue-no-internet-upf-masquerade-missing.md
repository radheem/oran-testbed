# 20260610 — UE attaches but no internet: UPF MASQUERADE missing

- **Date:** 2026-06-10
- **Area:** networking
- **Status:** Resolved
- **Components:** open5gs_5gc, multi_ue

> Single-cell ZMQ deployment. UE pool `10.45.0.0/16`, UPF tun `ogstun`.

## Summary
- After a successful attach (UE got `10.45.0.2`, default route via `tun_srsue`),
  `ping 8.8.8.8` from the UE netns was 100% loss and DNS failed.
- The UPF had no SNAT/MASQUERADE for the UE pool, so UE uplink left un-NAT'd and
  could not be routed back.
- Resolved by adding the masquerade rule in the Open5GS entrypoint.

## Context / setup
- UE traffic path: UE netns → `tun_srsue` → ZMQ → gNB → GTP-U → UPF `ogstun`
  (`10.45.0.0/16`) → 5gc container egress NIC (`eth0`) → host → internet.

## Investigation / what was determined
- `docker exec multi_ue ip netns exec ue1 ping -c4 8.8.8.8` → 100% loss.
- `docker exec open5gs_5gc ping -c2 8.8.8.8` → **works** (the container itself reaches
  the internet via `eth0`), so egress exists — only UE traffic was failing.
- `docker exec open5gs_5gc iptables -t nat -S POSTROUTING` → only Docker's default
  rule; **no** `10.45.*` MASQUERADE.
- `setup_tun.py`: `iptables_add_masquerade()` sets `rule.out_interface = ogstun`
  (the tun device, not the egress NIC) and uses python-iptables (`iptc`), which writes
  to the iptables-legacy backend while the kernel forwarding path uses nft — so the
  rule never took effect anyway.

## Root cause
- No effective SNAT for the UE pool on the egress interface. `setup_tun.py`'s iptc rule
  is both wrong (`-o ogstun` instead of the egress NIC) and in the wrong iptables
  backend, so UE packets egress with source `10.45.x.x` and the reply can't return.

## Resolution / workaround
- The Open5GS entrypoint now installs the rule explicitly (idempotent, correct
  interface):
  `iptables -t nat -A POSTROUTING -s <UE_pool>/16 ! -o ogstun -j MASQUERADE`.
- Verified: after the rule, `ping google.com` from the UE netns is 0% loss.

## Lessons / gotchas
- Test egress at each hop: the 5gc container reaching the internet ≠ UEs reaching it —
  the UE pool needs its own SNAT.
- On hosts with both nft and legacy iptables, python-iptables (`iptc`) may write to a
  backend the kernel isn't using; a plain `iptables` shell rule is more reliable.
- `! -o ogstun` (masquerade everything not bound to the tun) is interface-agnostic and
  survives a different egress NIC name.

## References
- `docker/open5gs/open5gs_entrypoint.sh`, `docker/open5gs/setup_tun.py`
