# 20260610 — gNB image fails to start: libmkl_rt.so.3 not found

- **Date:** 2026-06-10
- **Area:** bring-up
- **Status:** Resolved
- **Components:** ocudu_gnb

> Single-cell ZMQ deployment via `docker/docker-compose.zmq.yml`.

## Summary
- The `rptestbed/docker-gnb:latest` image exited immediately on start with
  `error while loading shared libraries: libmkl_rt.so.3: cannot open shared object file`.
- The binary was linked against Intel MKL at build time, but the runtime image did
  not ship the MKL runtime library.
- Resolved by using a build that does not link MKL; the later `:11062026` ocudu
  build links no MKL at all (`ldd` clean).

## Context / setup
- gNB service in `docker/docker-compose.zmq.yml`, image `rptestbed/docker-gnb:latest`
  (a stale 2026-05-06 build).

## Investigation / what was determined
- `docker logs ocudu_gnb` → the missing-shared-library error above.
- `docker run --rm --entrypoint sh rptestbed/docker-gnb:latest -c 'ldd /usr/local/bin/gnb | grep mkl'`
  → `libmkl_rt.so.3 => not found`.
- `find / -name 'libmkl_rt*'` inside the image → nothing; the lib was nowhere on the
  host or in any other image, so it could not be shimmed in at runtime.

## Root cause
- The image was compiled with MKL enabled (srsRAN/ocudu `srsvec` MKL backend) but the
  runtime stage of the Dockerfile never installed the MKL runtime, so the dynamic
  loader had no `libmkl_rt.so.3`. A pure packaging/build defect — nothing to fix at
  deploy time without a rebuild.

## Resolution / workaround
- Switched the gNB to an image that does not depend on MKL (interim
  `rptestbed/gnb:20260610-dpdk`, then the rebuilt `rptestbed/docker-gnb:11062026`,
  whose `ldd` shows no MKL).
- For future builds: either build with `-DENABLE_MKL=False` (srsRAN single-cell did
  this) or install the MKL runtime in the Dockerfile runtime stage.

## Lessons / gotchas
- "loading shared libraries: … not found" at startup = a runtime-deps packaging gap,
  not a config problem. Check `ldd` of the binary against what the runtime image ships.
- A binary that links MKL must ship the MKL runtime; the srsRAN build avoided this by
  disabling MKL for the ZMQ image.

## References
- `docker/docker-compose.zmq.yml`
- Related: [gNB SIGILL on a newer build host](./20260611-gnb-sigill-march-native.md)
