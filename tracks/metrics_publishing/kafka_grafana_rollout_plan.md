# Kafka-First Metrics + New Grafana Dashboards Rollout Plan

Date: 2026-07-14

## Goal
Move xApp and UE telemetry from direct InfluxDB writes to a Kafka-first pipeline:

1. xApps publish metrics to Kafka.
2. A dedicated consumer writes the Kafka payloads into InfluxDB.
3. Grafana reads only from InfluxDB.
4. Existing dashboards remain untouched; new dashboards are added under `monitoring/grafana/dashboards`.

## Current State
- Legacy xApps in `srssran-2-slice/oran-sc-ric/xApps/python` write KPM directly to InfluxDB through `lib/influx_writer.py`.
- UE traffic in `oran-testbed/ue/multi_ue/config/ue_export.py` already emits `ue_traffic` and `ue_latency` metrics directly to InfluxDB.
- The new testbed already has a Kafka + consumer pattern in `oran-testbed/docker-compose.pubsub.yml` and `oran-testbed/pubsub/consumer/`.
- Grafana in `oran-testbed/monitoring/grafana/` auto-loads JSON dashboards from `monitoring/grafana/dashboards`.

## Scope
Keep the existing dashboards in place:
- `monitoring/grafana/dashboards/home.json`
- `monitoring/grafana/dashboards/cu_cp.json`
- `monitoring/grafana/dashboards/ngap.json`
- `monitoring/grafana/dashboards/ofh.json`
- `monitoring/grafana/dashboards/performance.json`
- `monitoring/grafana/dashboards/rrc.json`

Add new dashboards only, for the Kafka-fed metrics views.

## Implementation Phases

### Phase 1: Define the Kafka metric contract
- Choose a single message schema for xApps and UE exporters:
  - `measurement`
  - `tags`
  - `fields`
  - `timestamp_ns`
  - `xapp` or `source`
- Preserve the field names already used by the dashboards where possible, so the consumer can write compatible Influx rows without dashboard rewrites.
- Keep the KPM measurement naming compatible with the current queries for `kpm`, `ue_traffic`, and `ue_latency`.

### Phase 2: Replace direct Influx writes in xApps with Kafka publishing
- Update the xApp code path that currently writes directly to Influx:
  - `srssran-2-slice/oran-sc-ric/xApps/python/kpm_mon_xapp.py`
  - `srssran-2-slice/oran-sc-ric/xApps/python/lib/influx_writer.py`
- Introduce a Kafka publisher helper in the xApp tree, or reuse the existing pubsub-style message envelope from `oran-testbed/pubsub/consumer/sinks.py`.
- Keep the xApp callback behavior best-effort: failures should not break subscriptions.
- For UE telemetry, either:
  - publish from `ue/multi_ue/config/ue_export.py` directly to Kafka, or
  - add a thin adapter that reuses the same Kafka schema as the xApp metrics.

### Phase 3: Add Kafka consumers that write to InfluxDB
- Extend the consumer service in `oran-testbed/pubsub/consumer/` so one sink reads the Kafka metric messages and writes them to InfluxDB.
- Keep the sink mapping simple:
  - `kpm` -> `kpm` measurement in InfluxDB
  - `ue_traffic` -> `ue_traffic`
  - `ue_latency` -> `ue_latency`
- Preserve tag keys and field names so the new dashboards can query the same logical series names.
- If needed, keep a separate Kafka consumer group for each sink so the pipeline can scale independently.

### Phase 4: Add new Grafana dashboards
- Create new dashboard JSON files under `oran-testbed/monitoring/grafana/dashboards`.
- Suggested new files:
  - `kpm_kafka.json`
  - `multi_ue_traffic_kafka.json`
  - `e2e_ue_kpm_gnb_kafka.json`
- Base the new dashboards on the existing dashboard layouts, but point them at the Kafka-fed Influx measurements.
- Do not overwrite or rename the existing dashboard JSON files.

### Phase 5: Wire the deployment
- Ensure the monitoring stack includes:
  - Kafka broker
  - consumer container(s)
  - InfluxDB writer target
  - Grafana provisioning that loads the new dashboards automatically
- Confirm the dashboard provisioning path still uses `monitoring/grafana/provisioning/dashboards/dashboardReference.yml` and the shared Influx datasource remains intact.

### Phase 6: Validation
- Verify the xApps publish Kafka messages for each metric family.
- Verify the consumer writes rows into the expected InfluxDB measurements.
- Verify the new dashboards render data from InfluxDB without editing the existing dashboards.
- Verify the old dashboards still open and continue reading their existing measurements.

## Acceptance Criteria
- KPM metrics produced by the xApp land in Kafka first.
- Kafka consumer writes those metrics into InfluxDB.
- Grafana dashboards read only from InfluxDB.
- Existing dashboards remain unchanged.
- New dashboards appear under `monitoring/grafana/dashboards` and visualize the Kafka-fed metrics.

## Suggested Work Order
1. Implement the Kafka publisher in the xApp and UE metric writers.
2. Extend or configure the consumer sink to write into InfluxDB.
3. Add new dashboards alongside the existing ones.
4. Start the pubsub stack and verify end-to-end metric flow.
