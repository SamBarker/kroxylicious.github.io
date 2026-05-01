---
layout: overview
title: Performance
permalink: /performance/
toc: true
---

This page summarises the measured performance overhead of Kroxylicious. Numbers come from [benchmarks run on real hardware](/blog/2026/05/01/benchmarking-the-proxy/) using [OpenMessaging Benchmark (OMB)](https://github.com/openmessaging/benchmark), an industry-standard Kafka performance tool.

## Test environment

| Component | Details |
|-----------|---------|
| CPU | AMD EPYC-Rome, 2 GHz |
| Cluster | 6-node OpenShift, RHCOS 9.6 |
| Kafka | 3-broker Strimzi cluster, replication factor 3 |
| Kroxylicious | 0.20.0, single proxy pod, 1000m CPU limit |
| KMS | HashiCorp Vault (in-cluster) |

All primary results used 1 KB messages on a single partition. Multi-topic workloads (10 and 100 topics) confirmed that overhead characteristics hold when load is distributed.

---

## Passthrough proxy (no filters)

The proxy layer itself adds negligible overhead. At sub-saturation rates the additional latency is sub-millisecond on average, with no measurable throughput impact.

**10 topics, 1 KB messages (5,000 msg/sec per topic):**

| Metric | Baseline | Proxy | Delta |
|--------|----------|-------|-------|
| Publish latency avg | 2.62 ms | 2.79 ms | +0.17 ms (+7%) |
| Publish latency p99 | 14.09 ms | 15.17 ms | +1.08 ms (+8%) |
| E2E latency avg | 94.87 ms | 95.34 ms | +0.47 ms (+0.5%) |
| Publish rate | 5,002 msg/s | 5,002 msg/s | no change |

**100 topics, 1 KB messages (500 msg/sec per topic):**

| Metric | Baseline | Proxy | Delta |
|--------|----------|-------|-------|
| Publish latency avg | 2.66 ms | 2.82 ms | +0.16 ms (+6%) |
| Publish latency p99 | 5.54 ms | 6.07 ms | +0.53 ms (+10%) |
| Publish rate | 500 msg/s | 500 msg/s | no change |

---

## Record encryption (AES-256-GCM)

Encryption adds measurable but predictable overhead. The cost scales with producer rate — well below saturation the overhead is small; approaching the saturation point, latency rises sharply.

### Latency at sub-saturation rates

**1 topic, 1 KB messages — baseline vs encryption:**

| Rate | Metric | Baseline | Encryption | Delta |
|------|--------|----------|------------|-------|
| 34,000 msg/s | Publish avg | 8.00 ms | 8.19 ms | +0.19 ms (+2%) |
| 34,000 msg/s | Publish p99 | 48.65 ms | 64.01 ms | +15.35 ms (+32%) |
| 36,000 msg/s | Publish avg | 9.38 ms | 10.46 ms | +1.08 ms (+12%) |
| 36,000 msg/s | Publish p99 | 63.92 ms | 88.98 ms | +25.06 ms (+39%) |
| 37,200 msg/s | Publish avg | 9.12 ms | 12.19 ms | +3.07 ms (+34%) |
| 37,200 msg/s | Publish p99 | 74.88 ms | 113.15 ms | +38.27 ms (+51%) |

### Throughput ceiling

| Scenario | Throughput ceiling (1 topic, 1 KB, 1 partition) |
|----------|------------------------------------------------|
| Baseline (direct Kafka) | ~50,000–52,000 msg/sec |
| Encryption (proxy + AES-256-GCM) | ~37,200 msg/sec |
| **Cost** | **~26% fewer messages per second per partition** |

---

## Sizing guidance

**Passthrough proxy**: size your Kafka cluster as you normally would. The proxy will not be the bottleneck.

**With record encryption:**

- **Throughput**: plan for ~25% lower throughput per partition compared to direct Kafka
- **Latency**: expect 0.2–3 ms additional average publish latency and 15–40 ms additional p99, scaling with how close to saturation you operate
- **Scaling**: the throughput ceiling is per-connection (one Netty event loop per client connection). Spreading load across more producers is the first scaling lever; adding proxy pods comes next
- **KMS**: DEK caching means the KMS is not on the hot path. In testing, each benchmark run triggered only 5–19 DEK generation calls — the KMS is not a bottleneck

---

## Further reading

- [Operator guide: results, methodology, and sizing recommendations](/blog/2026/05/01/benchmarking-the-proxy/) — the full benchmark story for operators
- [Engineering deep dive: tooling, flamegraphs, and what we discovered](/blog/2026/05/08/benchmarking-the-proxy-under-the-hood/) — how we measured it, where the CPU goes, and what surprised us
- [Benchmark quickstart](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-openmessaging-benchmarks/QUICKSTART.md) — run the benchmarks yourself