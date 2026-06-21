# Architecture

This document describes the complete architecture of the consolidated O-RAN testbed:
a 5G SA Open RAN stack (Open5GS 5GC + ORAN-SC near-RT RIC + OCUDU/srsRAN gNB), a
**publish/subscribe telemetry pipeline** (xApp → Kafka → N purpose-specific consumers),
and the integration points for the **O-RAN AI/ML Framework** and a **non-RT RIC rApp**.

For deployment steps see [SETUP.md](SETUP.md); for the scripted ZMQ end-to-end test see
[RUNBOOK_E2E_ZMQ.md](RUNBOOK_E2E_ZMQ.md).

---

## 1. System overview

The testbed produces RAN telemetry from two independent producers (the gNB's own JSON
metrics, and the KPM xApp over E2), and routes it to consumers. The **telemetry bus**
decouples the single xApp producer from N consumers, each persisting the stream into the
datastore its purpose needs.

```mermaid
flowchart TB
  subgraph ran["5G SA Open RAN testbed (Docker)"]
    UE["UE<br/>srsUE (ZMQ) / COTS phone (UHD)"]
    GNB["gNB<br/>OCUDU / srsRAN"]
    CORE["5GC — Open5GS<br/>AMF · SMF · UPF · UDM/UDR · NRF · PCF"]
    DN["Data network<br/>(internet)"]
    UE -->|Uu / ZMQ| GNB
    GNB -->|N2 NGAP · N3 GTP-U| CORE
    CORE -->|N6| DN
  end

  subgraph ric["ORAN-SC near-RT RIC"]
    E2T["e2term / e2mgr / submgr<br/>dbaas (Redis) · rtmgr · appmgr"]
    XAPP["KPM xApp<br/>kpm_mon_xapp"]
    GNB -->|E2 / E2SM-KPM| E2T
    E2T --> XAPP
  end

  subgraph bus["Telemetry pub/sub fan-out (one producer, N consumers)"]
    KAFKA["Kafka<br/>topic: xapp-metrics"]
    CM["consumer_mongo"]
    C2["consumer_influx2"]
    C3["consumer_influx3"]
    XAPP -->|publish JSON| KAFKA
    KAFKA -->|group cons-mongo| CM
    KAFKA -->|group cons-influx2| C2
    KAFKA -->|group cons-influx3| C3
  end

  subgraph sinks["Datastores & consumers"]
    MONGO[("MongoDB<br/>metrics.kpm")]
    I2[("InfluxDB 2<br/>primary/srsran")]
    I3[("InfluxDB 3<br/>srsran/kpm")]
    NRTRIC["non-RT RIC<br/>rApp"]
    AIML["O-RAN AI/ML Framework<br/>feature group → train → serve"]
    GRAF["Grafana<br/>dashboards"]
    CM --> MONGO --> NRTRIC
    C2 --> I2 --> AIML
    C3 --> I3 --> GRAF
  end

  TEL["Telegraf<br/>gNB JSON KPIs"]
  GNB -->|metrics WS :8001| TEL --> I3
```

**Two highest-value hand-offs:** the **non-RT RIC** (MongoDB → rApp) and the **AI/ML
Framework** (InfluxDB 2 → feature group). Grafana (InfluxDB 3) is the operational view.

---

## 2. Networks and host ports

All components attach to four **external Docker bridges** created by
`scripts/net_manage.sh init` (bridge-only — no macvlan, no host-interface setup).

| Network | Subnet | Carries |
|---|---|---|
| `n2` | `10.53.1.0/24` | NGAP (SCTP) **+ NG-U GTP-U**, 5GC ↔ gNB |
| `n3` | `10.10.0.0/16` | **ZMQ RF transport**, gNB ↔ multi_ue (*not* 3GPP N3) |
| `oran-sc-ric` | `10.0.2.0/24` | E2, gNB ↔ RIC |
| `metrics` | `172.19.1.0/24` | telemetry: telegraf/influx/grafana, Kafka, Mongo, consumer, xApp, UE export |

**Principle:** the 5GC and RIC **publish host ports** so any number of gNBs (local, other
compose projects, remote hosts) can attach; **gNB containers publish nothing** and reach the
core/RIC over the shared bridges (or, for remote gNBs, the host ports).

```mermaid
flowchart LR
  subgraph host["Host-published ports"]
    P5["5GC: 38412/sctp · 2152/udp · 9999/tcp"]
    PR["RIC: 36421/sctp · 8080/tcp"]
    PX["Grafana 3300 · InfluxDB2 8086 · Mongo 27017 · Kafka 29092"]
  end
  P5 -. external/remote gNBs .-> CORE["5GC"]
  PR -. external/remote gNBs .-> RICN["RIC e2term"]
```

**Fixed addresses** (defaults in `.env`): 5GC `10.53.1.2`, gNB `10.53.1.3` (n2) /
`10.10.3.231` (n3 ZMQ) / `10.0.2.25` (E2) / `172.19.1.3` (metrics); e2term `10.0.2.10`;
multi_ue `10.10.4.237`. Metrics bridge: telegraf `.4`, InfluxDB 3 `.5`, Grafana `.6`,
Kafka `.7`, Mongo `.8`, consumer `.9`, InfluxDB 2 `.10`, xApp runner `.20`, multi_ue `.23`.

> **Why N3 GTP-U rides `n2`:** in the ZMQ topology the `n3` bridge is the *ZMQ transport
> wire* between gNB and multi_ue. The real 3GPP NG-U GTP-U flows over `n2` (5GC `10.53.1.2`
> ↔ gNB `10.53.1.3`), alongside NGAP.

---

## 3. Components

| Group | Containers | Role |
|---|---|---|
| **Core** | `open5gs_5gc` | 5G SA core (AMF/SMF/UPF/UDM/UDR/NRF/PCF) + internal Mongo subscriber DB; provisioned via `open5gs-dbctl` |
| **RIC** | `ric_e2term`, `ric_e2mgr`, `ric_submgr`, `ric_appmgr`, `ric_rtmgr_sim`, `ric_dbaas` (Redis), `python_xapp_runner` | ORAN-SC near-RT RIC + xApp host (E2SM-KPM/RC/CCC) |
| **gNB** | `ocudu_gnb` | OCUDU/srsRAN gNB (ZMQ or UHD); docker-net only, no host ports |
| **UE** | `multi_ue` | N srsUEs + co-located ZMQ bridge (ZMQ only) |
| **Monitoring** | `telegraf`, `influxdb` (v3), `grafana` | gNB JSON KPIs → InfluxDB 3 → Grafana |
| **Pub/sub** | `kafka`, `metrics_mongo`, `influxdb2`, and three consumers `consumer_mongo` / `consumer_influx2` / `consumer_influx3` | telemetry bus + one consumer per sink (same image, different `SINK`/subscription/DB env) |

Lifecycle is driven by `scripts/manage.sh <start|stop> <core|ric|gnb|multi_ue|monitoring|pubsub|all>`.

---

## 4. Control plane, user plane and E2

```mermaid
flowchart LR
  UE["UE"] -->|"RRC / NAS (Uu or ZMQ)"| GNB["gNB"]
  GNB -->|"N2 NGAP (SCTP :38412)"| AMF["AMF"]
  GNB -->|"N3 GTP-U (UDP :2152)"| UPF["UPF"]
  AMF --- SMF["SMF"] --- UPF
  AMF -->|"Nudm/Nudr"| UDR["UDM/UDR"]
  UPF -->|"N6 + NAT"| NET["internet"]
  GNB -->|"E2 (SCTP :36421)"| E2T["RIC e2term"]
  E2T -->|"RMR"| SUB["submgr / xApp"]
```

- **N2 / E2** are gNB-initiated SCTP → publishing the AMF/e2term host ports is enough for
  remote gNBs (replies return on the association).
- **N3 GTP-U** is bidirectional → the gNB shares the `n2` bridge with the UPF so downlink
  GTP-U can reach the gNB's advertised address.
- **Subscriber provisioning** uses canonical `open5gs-dbctl` (raw Mongo inserts produce
  documents the UDR rejects at registration — see [SETUP.md](SETUP.md)).

### RF variants

```mermaid
flowchart TB
  subgraph zmq["ZMQ (virtual RF)"]
    GZ["gNB device_driver: zmq<br/>tx tcp://10.10.3.231:2000"]
    MU["multi_ue<br/>N srsUE + bridge @ 10.10.4.237"]
    GZ <-->|"ZMQ over n3"| MU
  end
  subgraph uhd["UHD (physical SDR)"]
    GU["gNB device_driver: uhd"]
    B210["USRP B210 (USB)"]
    PH["COTS phone + USIM"]
    GU --- B210
    B210 -. over the air .-> PH
  end
```

---

## 5. Telemetry pub/sub pipeline

The KPM xApp publishes each E2SM-KPM indication **once** to Kafka; **three independent
consumers** (same image, different `SINK` + subscription + DB params, each in its own Kafka
**consumer group** so every consumer receives every message) fan it out to three datastores.
Producers and consumers are decoupled — a new purpose is added by attaching another consumer,
with no change to the xApp.

```mermaid
flowchart LR
  DU["gNB DU<br/>E2SM-KPM (DRB.UEThpDl/Ul)"]
  XAPP["kpm_mon_xapp<br/>MetricsPublisher (METRICS_BACKEND=kafka)"]
  KAFKA["Kafka<br/>topic: xapp-metrics"]
  DU -->|E2 indication| XAPP -->|"JSON publish"| KAFKA

  C3["consumer_influx3<br/>SINK=influx"]
  C2["consumer_influx2<br/>SINK=influx"]
  CM["consumer_mongo<br/>SINK=mongo"]
  KAFKA -->|group cons-influx3| C3
  KAFKA -->|group cons-influx2| C2
  KAFKA -->|group cons-mongo| CM

  C3 -->|"line protocol"| I3[("InfluxDB 3<br/>srsran/kpm")] --> G["Grafana"]
  C2 -->|"line protocol"| I2[("InfluxDB 2<br/>primary/srsran")] --> A["AI/ML Framework<br/>feature group"]
  CM -->|"insert_one + createdon"| M[("MongoDB<br/>metrics.kpm")] --> R["non-RT RIC rApp"]
```

**Each consumer is configured by env** — subscription: `KAFKA_BOOTSTRAP_SERVERS`,
`KAFKA_TOPIC`, `KAFKA_GROUP_ID`, `KAFKA_OFFSET_RESET`; output: `SINK` (`influx`\|`mongo`) plus the
sink's DB params (`INFLUX_URL`/`INFLUX_BUCKET`/`INFLUX_ORG`/`INFLUX_TOKEN`, or
`MONGO_URI`/`MONGO_DB`/`MONGO_TIMEOUT_MS`). Implementation: `pubsub/consumer/consumer.py`
(generic Kafka loop) + `sinks.py` (pluggable `InfluxSink`/`MongoSink`, registered in `SINKS`);
the three services share one image via YAML anchors in `docker-compose.pubsub.yml`. Adding a
sink = a class in `sinks.py` + a service block.

**Message schema** (JSON on `xapp-metrics`):

```json
{
  "measurement": "kpm",
  "tags": { "e2_node_id": "gnbd_001_001_000001_0", "report_style": 1, "ue_id": "cell" },
  "fields": { "DRB_UEThpDl": 414.0, "DRB_UEThpUl": 407.0 },
  "timestamp_ns": 1782076183419887502,
  "xapp": "kpm"
}
```

**Per-consumer persistence:**

| Sink | Target | Notes |
|---|---|---|
| InfluxDB 3 | `srsran/kpm` (line protocol, `/api/v2/write`) | Grafana feed; dots → underscores in field keys |
| InfluxDB 2 | `primary/srsran`, measurement `kpm` (port 8086, token-auth) | **same version the AIMLFW uses**; data written *as-is* |
| MongoDB | `metrics.kpm` | full document + `ingested_at_ns` + **`createdon`** (xApp created-at as UTC ISO string, fallback `now(UTC)`) |

Producer: `ric/xApps/python/lib/metrics_publisher.py` + factory `metrics_writer.py`.
Consumers: one image (`pubsub/consumer/consumer.py` + `sinks.py`, vendoring `influx_writer.py`)
run as three services in `docker-compose.pubsub.yml`.

### End-to-end KPM sequence

```mermaid
sequenceDiagram
  participant DU as gNB DU
  participant E2 as RIC (e2term/submgr)
  participant X as kpm_mon_xapp
  participant K as Kafka
  participant C3 as consumer_influx3
  participant C2 as consumer_influx2
  participant CM as consumer_mongo
  X->>E2: RIC Subscription (E2SM-KPM, style 1)
  E2->>DU: Subscription Request
  loop every report period
    DU->>E2: RIC Indication (DRB.UEThpDl/Ul)
    E2->>X: forward indication (RMR)
    X->>K: publish JSON (xapp-metrics)
    par one copy per consumer group
      K->>C3: deliver
      C3->>C3: write InfluxDB 3
    and
      K->>C2: deliver
      C2->>C2: write InfluxDB 2
    and
      K->>CM: deliver
      CM->>CM: write MongoDB (+createdon)
    end
  end
```

---

## 6. Downstream integration

- **O-RAN AI/ML Framework (AIMLFW).** The InfluxDB 2 sink (`primary/srsran`, token-compatible)
  is exactly the datastore the AIMLFW reads. Live KPM lands there continuously, so the same
  **feature-group → data-extraction → Kubeflow training → KServe serving** lifecycle the
  AIMLFW already runs applies to live data (not only the `cells.csv` bootstrap). Point a
  feature group at bucket `srsran`, measurement `kpm`, fields `DRB_UEThpDl`/`DRB_UEThpUl`.
- **Non-RT RIC.** The MongoDB collection `metrics.kpm` is the hand-off for a non-RT RIC
  **rApp**: a non-real-time analytics/control loop reads the document store (each record
  carries `createdon`), e.g. to drive policy back toward the near-RT RIC.

```mermaid
flowchart LR
  I2[("InfluxDB 2<br/>srsran/kpm")] --> FG["feature group<br/>(qoe features)"]
  FG --> DEX["data extraction"] --> CAS["Cassandra<br/>feature store"]
  CAS --> KF["Kubeflow<br/>LSTM training"] --> OBJ["model artifact"]
  OBJ --> KS["KServe<br/>InferenceService"] --> PRED["prediction"]
  M[("MongoDB<br/>metrics.kpm")] --> RAPP["non-RT RIC rApp<br/>(analytics / policy)"]
```

---

## 7. Build and deploy notes

- **gNB image:** pulled by default (`GNB_IMAGE`); the OCUDU source is vendored at
  `src/ocudu/` and can be built locally with
  `docker build -f src/ocudu/docker/Dockerfile --build-arg ENABLE_ZEROMQ=On --build-arg MARCH=x86-64-v4 -t <tag> src/ocudu`.
  **`MARCH` must be ≤ the run host's CPU ISA** or the gNB SIGILLs (exit 132) once the PHY runs.
- **Config schema coupling:** the OCUDU `docker-gnb` image uses **plural** `addrs`/`bind_addrs`;
  the srsRAN `gnb` image uses **singular** `addr`/`bind_addr` (see comments in
  `configs/gnb_zmq.yml`).
- **Open5GS / RIC:** 5GC built from `open5gs/`; RIC mostly pulled from `nexus3.o-ran-sc.org`.
- **Start order (full stack):** `net_manage.sh init` → `manage.sh start core` (provision UEs)
  → `start ric` (self-heals e2mgr/e2term) → `start monitoring` → `start pubsub` →
  `start gnb` → `start multi_ue`. Restart order matters: **RIC before gNB** (the gNB sets up
  E2 once and does not auto-reconnect).
