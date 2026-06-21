# 20260611 — gNB crashes with SIGILL once PHY runs (march mismatch)

- **Date:** 2026-06-11
- **Area:** bring-up
- **Status:** Mitigated (requires gNB image rebuild by the image owner)
- **Components:** ocudu_gnb

> Single-cell ZMQ deployment; ocudu image `rptestbed/docker-gnb:11062026`.
> Test host: Intel Xeon 8259CL (Cascade Lake, x86-64-v4).

## Summary
- The gNB starts and idles fine (`Waiting for data`), the UE completes RACH + RRC
  Connected, then the gNB **crashes the instant PHY/DSP processing starts**.
- Container exit code **132 = 128 + 4 = SIGILL** (illegal instruction).
- The image was built with `-march=native` on a build host newer than the Cascade Lake
  testbed, so the binary uses instructions this CPU lacks — only hit on the DSP hot path.
- Mitigation: rebuild the gNB with `MARCH` ≤ the testbed CPU (never `-march=native` on a
  newer host). This is the primary blocker for the `:11062026` build.

## Context / setup
- gNB serves over ZMQ; real PHY DSP (FFT / channel estimation / LDPC) only runs once a
  UE is exchanging samples.

## Investigation / what was determined
- `docker inspect ocudu_gnb` → `ExitCode=132`, `OOMKilled=false`. `132 - 128 = 4 = ILL`.
- `/tmp/gnb.log` (from the `gnb-storage` volume) shows the UE attaching cleanly —
  `rrcSetupRequest`, `rrcSetup`, MAC/RLC/PDCP creation, first PDSCH — then stops dead
  mid-slot. No MKL/config error.
- AMF log: `gNB-N2 accepted[10.53.1.3]` then, ~minutes later,
  `gNB-N2[10.53.1.3] connection refused!!!` — i.e. the N2 SCTP dropped because the gNB
  process died.
- Host CPU: `Xeon 8259CL` with `avx512f/dq/cd/bw/vl` (x86-64-v4). A SIGILL on a v4 host
  means the binary targets an even newer ISA (e.g. Ice Lake VBMI2 / Sapphire Rapids
  AMX / AVX512-FP16) than Cascade Lake implements.

## Root cause
- The gNB image was compiled with `-march=native` on a build host with a newer CPU than
  the Cascade Lake test machine. Idle/control code avoids the unsupported instructions;
  the DSP hot path (reached only when a UE connects) executes one and the CPU raises
  SIGILL. This is a build-portability defect, not a logic bug (those would be
  SIGSEGV/SIGABRT, not SIGILL).

## Resolution / workaround
- Rebuild the gNB image targeting an ISA ≤ the testbed CPU. Options:
  - build *on* the test machine (`native` = `cascadelake`), or
  - `docker build --build-arg MARCH=x86-64-v4 -t rptestbed/docker-gnb:<tag> -f docker/Dockerfile .`
    (`x86-64-v4` keeps AVX-512 on this Cascade Lake; use `x86-64-v3` for an older node).
- Added `MARCH: ${MARCH:-x86-64-v4}` to the gNB build args in
  `docker/docker-compose.zmq.yml` (with a warning comment) so a `docker compose build`
  never uses `-march=native`.
- Status: until the image is rebuilt with a compatible `MARCH`, the end-to-end test
  cannot pass on this host.

## Lessons / gotchas
- Exit 132 / SIGILL on a binary that ran fine while idle ⇒ ISA mismatch in a hot code
  path; suspect `-march=native` built on a different (newer) CPU than the runtime host.
- Never ship `-march=native` artifacts to heterogeneous hardware; pin `MARCH` to the
  lowest-common-denominator CPU of the fleet.
- The gNB dying takes the N2 SCTP down — "connection refused" in the AMF can be a
  downstream symptom of a gNB crash, not a networking fault.

## References
- `docker/docker-compose.zmq.yml` (MARCH build arg)
- Related: [gNB image missing libmkl_rt](./20260610-gnb-image-missing-libmkl-rt.md)
