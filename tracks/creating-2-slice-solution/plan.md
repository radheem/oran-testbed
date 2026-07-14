# Creating a 2-Slice ZMQ Solution

## Goal

Add a separate ZMQ two-slice scenario to `oran-testbed` without changing the existing single-slice ZMQ path.

The new scenario should reuse the same 5GC and RIC, add a second gNB with its own IPs and ZMQ ports, and add two more UEs that attach to slice 2.

## Scope

- New gNB compose for the 2-slice scenario.
- New UE/multi-UE scenario for routing UEs across two cells.
- New subscriber data for the slice-2 UEs.
- New runbook under `docs/` for bring-up, verification, traffic, and teardown.
- Minimal lifecycle wiring so the new scenario can be started and stopped cleanly.

## Implementation Plan

### 1. Add a dedicated two-slice gNB compose

Create a new compose file, for example `docker-compose.zmq-2-slice.yml`.

Include:

- `gnb` for cell 1.
- `gnb2` for cell 2.

Keep these shared with the existing project:

- the same 5GC container and network wiring.
- the same RIC and E2 setup.
- the same monitoring pipeline.

Give `gnb2` its own values for:

- N2 IP
- N3 IP
- E2 bind IP
- metrics IP
- ZMQ TX/RX ports

Keep cell 1 on `sst=1` and cell 2 on `sst=2`.

### 2. Add a dedicated two-slice UE scenario

Create a sibling directory such as `ue/multi_ue-2-slice`.

Reuse the current `multi_ue` model, but make the cell split explicit:

- UE1 and UE2 attach through bridge 1 to gNB1.
- UE3 and UE4 attach through bridge 2 to gNB2.

The UE container should still be a single multi-UE container with per-UE netns and per-UE ZMQ ports.

Keep the routing logic in the bridge/start scripts, not in the RAN config.

### 3. Add slice-2 subscribers

Create a CSV or override file for the two new UEs.

Requirements:

- UE3 and UE4 must be provisioned on `sst=2`.
- Keep the same DNN and IP pool unless there is a specific reason to change them.
- Leave slice 1 subscribers unchanged.

This keeps slice assignment in Open5GS, which is the right place for it.

### 4. Add lifecycle wiring

Expose the new scenario through `scripts/manage.sh` or a small scenario wrapper.

Recommended approach:

- add explicit start/stop targets for the 2-slice gNB stack;
- add explicit start/stop targets for the 2-slice UE stack;
- keep the current single-slice commands untouched.

This makes the scenario easy to operate and avoids regressions in the baseline setup.

### 5. Add a dedicated runbook

Create a new runbook under `docs/`, for example `docs/RUNBOOK_2GNB_2SLICE.md`.

Document:

- prerequisites
- container and network startup order
- subscriber provisioning for slice 2
- UE-to-cell mapping
- verification commands
- traffic generation
- KPM checks
- teardown and recovery order

Cross-link the new runbook from `docs/SETUP.md` and the top-level README.

## Testing Plan

### A. Static checks

- Confirm the new compose file parses cleanly.
- Confirm the new UE scenario scripts resolve the expected IPs and ports.
- Confirm the runbook reflects the actual filenames and startup order.

### B. Bring-up smoke test

1. Start the existing 5GC and RIC.
2. Start the 2-slice gNB stack.
3. Verify both gNBs complete E2 setup and appear in the RIC.
4. Start the 2-slice UE container.
5. Verify UE1/UE2 attach to cell 1 and UE3/UE4 attach to cell 2.

Pass criteria:

- both gNBs are healthy;
- both E2 nodes register;
- all four UEs get PDU sessions;
- each cell serves two UEs.

### C. Slice validation

- Confirm UE1/UE2 traffic lands on slice 1.
- Confirm UE3/UE4 traffic lands on slice 2.
- Confirm Open5GS subscriber state shows the correct `sst` values.

Pass criteria:

- slice 1 UEs attach and pass traffic on `sst=1`;
- slice 2 UEs attach and pass traffic on `sst=2`.

### D. Data-plane validation

- Run bounded traffic per UE.
- Verify ping from each UE to `10.45.0.1`.
- Verify per-UE throughput export still works.

Pass criteria:

- traffic flows on all four UEs;
- no UE wedges during normal bounded runs.

### E. KPM validation

- Run the KPM xApp against gNB1.
- Run the KPM xApp against gNB2.
- Verify both report the expected throughput metrics for the active UEs.

Pass criteria:

- both gNBs expose KPM;
- KPM data is visible per `e2_node_id`;
- reported throughput changes with traffic load.

### F. Recovery validation

- Stop the UE stack, then the gNB stack, then restart in the documented order.
- Verify the system comes back without stale E2 state.

Pass criteria:

- clean restart restores both gNBs and both E2 paths;
- UEs reattach without manual container surgery.

## Suggested Acceptance Criteria

- The existing single-slice ZMQ workflow still works unchanged.
- A new two-slice workflow exists with separate compose and UE scenario assets.
- Four UEs can attach, two per cell, with slice-appropriate subscriptions.
- Both gNBs register in E2 and produce KPM.
- The runbook is sufficient for a full clean bring-up and teardown.

## Implementation Order

1. Add the new gNB compose and cell-2 config wiring.
2. Add the new UE scenario directory and bridge logic.
3. Add slice-2 subscriber overrides.
4. Wire the new scenario into the lifecycle scripts.
5. Write the runbook.
6. Run smoke tests, then traffic tests, then KPM checks.
