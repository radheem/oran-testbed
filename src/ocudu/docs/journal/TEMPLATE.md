# YYYYMMDD — <short imperative/descriptive title>

- **Date:** YYYY-MM-DD
- **Area:** <networking | RAN / slicing | E2 / KPM | traffic / stability | bring-up>
- **Status:** <Resolved | Mitigated | Open | Investigating | Superseded>
- **Components:** <open5gs_5gc, ocudu_gnb, multi_ue, monitoring, …>

> Optional one-line scope note (e.g. "Paths are relative to the repo root
> `/home/radr/pers/internship/ocudu/`; single-cell ZMQ deployment via
> `docker/docker-compose.zmq.yml`.").

## Summary
- 2–5 bullets: the symptom, the root cause, and the outcome in plain language.
- State up front whether this is a fault that was fixed, a mitigation, or an open
  limitation.

## Context / setup
- The relevant slice of the topology / stack for this entry (which containers,
  networks, IPs, configs are involved). Don't re-document the whole runbook — link it.

## Investigation / what was determined
- The steps taken and the evidence, in order. Include the commands run and the key
  log lines / query output that pinpointed the cause. Trim repetitive raw dumps to a
  representative sample.

## Root cause
- The actual cause, stated precisely. Distinguish a real fault from expected behaviour
  or an environmental limit.

## Resolution / workaround
- What fixed it (or the current mitigation). List concrete config/code changes with
  file paths. If unresolved, state the recommended next steps and any open decision.

## Lessons / gotchas
- Reusable takeaways and traps for the next person (and the next run).

## References
- Files changed, related journal entries (`[...](./file.md)`), runbook sections.

---
*Conventions: filename `YYYYMMDD-kebab-slug.md`. Keep the header block (Date / Area /
Status / Components) so the README index can be regenerated. Newest entries are listed
first in [README.md](./README.md).*
