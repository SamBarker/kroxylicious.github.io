---
layout: post
title: "Kroxylicious release 0.24.0"
date: 2026-09-04 15:00:00 +1200
author: "Sam Barker"
author_url: "https://github.com/sambarker"
# noinspection YAMLSchemaValidation
categories: blog kroxylicious-proxy
tags: [ "routing" ]
---

# Layer 7 Kafka Routing: A Pattern Taxonomy for the Consolidation Minefield

If you've ever tried to migrate a live Kafka workload between clusters, consolidate regional deployments, or shift cloud providers, you already know the bottom line: Kafka clients are remarkably opinionated about network topology. They don't just talk to a virtual endpoint; they demand exact broker metadata, explicit partition assignments, and direct TCP connections to specific physical nodes.

When you try to reshape that underlying physical infrastructure without breaking application teams, you usually end up picking which operational headache you dislike the least.

## Pick your poison: Dual writes, MirrorMaker, or scheduled downtime

Before looking at proxy-level patterns, it helps to review the standard tools people use when trying to move or consolidate Kafka traffic—and why they so often result in late-night incident reviews.

* **Application-level dual writes:** You ask application teams to update their producer code to write to both Cluster A and Cluster B simultaneously. In architectural diagrams, this looks clean. In production, network blips cause asymmetric failures, message ordering drifts instantly, and handling duplicate delivery becomes the application's problem. Worse, getting twenty product teams to deploy matching code changes on the same timeline is an exercise in cat-herding.
* **Replication pipelines (MirrorMaker 2, etc.):** Running an intermediary replication cluster works reasonably well for asynchronous backup, but relying on it for live consolidation adds latency, doubles your storage and network bills, and forces consumers to deal with offset translation. You're essentially running twice as much hardware to move bytes you already owned.
* **Hard cutovers and maintenance windows:** You schedule a Sunday 2:00 AM window, drain topic queues, update DNS records, and restart clients. This is conceptually simple right up until a legacy service ignores DNS TTLs, holds onto stale socket connections indefinitely, and drops messages silently when the old brokers finally go dark.

Intercepting traffic at Layer 7—the Kafka wire protocol itself—offers an alternative. By placing a proxy like Kroxylicious between clients and brokers, we can manipulate metadata and route requests on the fly.

To be clear: introducing an L7 proxy adds a hop, consumes CPU, and gives you another piece of infrastructure to manage. If a simple DNS CNAME flip actually solves your problem, do that instead. But when you need to decouple physical cluster topologies from what clients see, proxying gives you control back.

---

## Where does the proxy run? Forward, Reverse, and Sidecars

Choosing a routing pattern is only half the battle. You also have to decide where the proxy tier physically lives, who owns it, and whether it acts as a forward proxy for egress or a reverse proxy for ingress.

```
                  ┌─────────────────────────────────────────────────────────┐
                  │                      FORWARD PROXY                      │
                  │                   (Client-Side Egress)                  │
                  │  ┌───────────────────────┐   ┌───────────────────────┐  │
                  │  │  Client App + Pod     │   │ Client Cluster        │  │
                  │  │  Sidecar Proxy        │   │ Centralized Gateway   │  │
                  │  └───────────┬───────────┘   └───────────┬───────────┘  │
                  └──────────────┼───────────────────────────┼──────────────┘
                                 │                           │
                   NETWORK BOUNDARY / TRANSIT / VPC PEERING  │
                                 │                           │
                  ┌──────────────┼───────────────────────────┼──────────────┐
                  │              ▼                           ▼              │
                  │  ┌───────────────────────┐   ┌───────────────────────┐  │
                  │  │ Broker Cluster        │   │ Broker Node +         │  │
                  │  │ Ingress Gateway       │   │ Broker Sidecar Proxy  │  │
                  │  └───────────────────────┘   └───────────────────────┘  │
                  │                      REVERSE PROXY                      │
                  │                   (Broker-Side Ingress)                 │
                  └└─────────────────────────────────────────────────────────┘

```

### The Forward Proxy Model (Client-Side Egress)

Lives in the client's network boundary and is managed by application or client-platform teams.

* **Client Cluster Gateway:** A shared proxy fleet inside the client Kubernetes cluster or VPC. Applications point to a local gateway service, and the proxy handles cross-cluster egress across network boundaries.
* **App Pod Sidecar:** Co-located inside the application pod as an egress proxy. Crucially, the proxy does *not* flatten or hide the Kafka cluster model—the client driver still receives metadata mapped to local endpoints (e.g., port ranges on `localhost`) and maintains individual TCP sockets per broker. You get isolated blast radius per pod, but running hundreds of Netty/JVM proxy containers across a microservice fleet levies a noticeable baseline memory tax.

### The Reverse Proxy Model (Broker-Side Ingress)

Lives in the Kafka cluster's network boundary and is managed by the central infrastructure/platform team.

* **Broker Cluster Ingress Gateway:** A shared ingress fleet sitting in front of physical Kafka brokers. Provides a unified front door for incoming client connections and shields underlying cluster topology, though a gateway outage impacts all incoming traffic.
* **Broker Node Sidecar:** Co-located on the actual physical broker hardware (one proxy instance per broker node). While it eliminates an internal network hop on paper, almost nobody does this in production. You risk L7 proxy bugs or memory spikes starving the underlying broker JVM or page cache, and a broker-side proxy loses most of its cross-cluster routing superpowers anyway.

---

## The four L7 traffic patterns

With deployment boundaries established, here are the four architectural patterns we use to manipulate Kafka traffic at Layer 7.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kroxylicious L7 Proxy                        │
├─────────────────┬─────────────────┬──────────────┬──────────────┤
│ Cluster Aliasing│ Union Clusters  │ Union Topics │ Topology-    │
│                 │                 │              │ Aware        │
│ [Virtual A]     │ [Virtual Hub]   │ [Logical T]  │ [AZ-a Client]│
│      │          │   ┌─────┴─────┐ │  ┌─────┴───┐ │      │       │
│      ▼          │   ▼           ▼ │  ▼         ▼ │      ▼       │
│ [Physical A/B]  │ [Phys 1] [Phys 2]│ [P0-1]  [P2-3]│ [Broker-a]   │
└─────────────────┴─────────────────┴──────────────┴──────────────┤
                                                                  │
                                 ▼                                │
┌─────────────────────────────────────────────────────────────────┐
│                    Physical Kafka Clusters                      │
└─────────────────────────────────────────────────────────────────┘

```

### 1. Cluster Aliasing

**What it is:** Mapping a static virtual cluster endpoint to actual physical backend clusters, allowing you to switch the target backend at the proxy layer without reconfiguring or restarting clients.

**How it works:** Clients connect to `kafka-virtual.company.internal`. The proxy inspects incoming Kafka frames (`Produce`, `Fetch`, `Metadata`) and maps them to physical brokers in `cluster-blue`. When you want to migrate to `cluster-green`, you update the proxy's routing target. The proxy handles the connection handoff to the new brokers under the hood.

**Real-world caveat:** Swapping backend targets at the proxy layer solves client connectivity, but it doesn't magically sync topic data or offset state between backends. If you flip the pointer without state replication, your consumers will hit offset mismatches. (We'll cover how we pair this with byte-level replication and KIP-1279 in Post 2).

### 2. Union Clusters

**What it is:** Exposing multiple distinct backend physical clusters through a single virtual cluster endpoint.

**How it works:** The proxy intercepts `Metadata` requests and synthesizes a single, unified cluster layout for the client. To an incoming producer or consumer, it looks like one massive cluster. Behind the scenes, the proxy routes requests for `orders-*` topics to a high-throughput physical cluster, while `analytics-*` topics head to a cheaper, storage-optimized cluster.

**Real-world caveat:** Namespace collisions will ruin your day. If `orders-v1` exists on two backend clusters, the proxy has to decide which physical cluster wins or enforce explicit topic-prefix rules. Also, we haven't benchmarked proxy metadata synthesis overhead at tens of thousands of topics across dozens of physical backends yet, so expect memory usage to scale with metadata volume.

### 3. Union Topics

**What it is:** Presenting a single logical Kafka topic to clients while sharding its underlying partitions across multiple physical clusters.

**How it works:** A client asks for metadata for topic `events`, which appears to have 32 partitions. The proxy returns metadata where partitions 0–15 point to physical brokers in Cluster A, and partitions 16–31 point to physical brokers in Cluster B. When a client sends a `ProduceRequest` for partition 20, the proxy routes those specific frames to Cluster B.

**Real-world caveat:** Transaction coordinator boundaries stop working cleanly here. If your applications rely on multi-topic transactions or read-committed isolation levels across partitions, splitting a topic across physical cluster boundaries breaks those guarantees today. Treat this pattern as a fit for simple, un-keyed, or independently partition-keyed workloads until proxy transaction handling matures.

### 4. Topology-Aware Routing

**What it is:** Directing client traffic dynamically based on client metadata, network topology, or locality attributes (like cloud availability zones).

**How it works:** Kafka cross-AZ data transfer fees are a recurring budget surprise for infra teams. With topology-aware routing, the proxy reads client IP blocks or rack attributes and routes fetch requests to brokers or read-replicas inside the same availability zone, cutting down on inter-zone bandwidth costs.

**Real-world caveat:** Local routing savings disappear if your proxy fleet is deployed inefficiently. If a client in `us-east-1a` sends frames to a proxy instance running in `us-east-1b`, which then forwards bytes to a broker in `us-east-1a`, you've just doubled your cross-AZ costs instead of eliminating them. Proxy placement must match client topology.

---

## What's next

This taxonomy gives us a common vocabulary for describing how L7 proxies reshape Kafka traffic and where they fit into physical deployment topologies. Over the coming weeks leading up to Current in San Francisco, we're going to dive deeper into the actual implementations.

Next week in Post 2, we'll take a close look at **Active-Passive DR with KIP-1279 & Cluster Aliasing**, breaking down how Virtual Cluster Keys swap backend targets without dropping client sockets, and showing the code behind our live demo.

If you're playing with Kafka traffic routing, building custom extensions, or just want to tell us where our architecture assumptions are wrong, drop by our [GitHub](https://github.com/kroxylicious/kroxylicious?utm_source=gemini), join us on [Slack](https://www.google.com/search?q=https://kroxylicious.slack.com&utm_source=gemini), or find us on [Bluesky](https://bsky.app/profile/kroxylicious.io?utm_source=gemini).
