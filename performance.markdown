---
layout: overview
title: Performance
permalink: /performance/
toc: true
---

This page summarises the measured performance overhead of Kroxylicious. Numbers come from [benchmarks run on real hardware](/blog/2026/05/21/benchmarking-the-proxy/) using [OpenMessaging Benchmark (OMB)](https://github.com/openmessaging/benchmark), an industry-standard Kafka performance tool. No, we didn't run this on a laptop — it's a realistic deployment: a 6-node OpenShift cluster on Fyre, IBM's internal cloud platform — a controlled environment.

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

Numbers without guidance aren't very useful, so here's how to translate these results into pod specs.

**Passthrough proxy**: size your Kafka cluster as you normally would. The proxy will not be the bottleneck.

**With record encryption:**

- **Throughput**: use `proxy CPU (millicores) = 20 × produce throughput (MB/s)` as a planning formula, then add ×1.3 headroom. Assumes matched consumer load and AMD EPYC-Rome 2 GHz with AES-NI — calibrate on your hardware. Validated at 1000m, 2000m, and 4000m. Example: 100k msg/s at 1 KB = 100 MB/s produce → 2000m + headroom → ~2600m.
- **Latency**: expect 0.2–3 ms additional average publish latency and 15–40 ms additional p99, scaling with how close to saturation you operate
- **Scaling**: set `requests` equal to `limits` in your pod spec to make the CPU budget — and therefore the throughput ceiling — deterministic. Increase the CPU limit to raise throughput; add proxy pods for redundancy.
- **KMS**: DEK caching means the KMS is not on the hot path. In testing, each benchmark run triggered only 5–19 DEK generation calls — the KMS is not a bottleneck

---

## Caveats

These numbers come from a single proxy pod, 1 KB messages, and single-pass measurements. A few things that matter when applying them to your workload:

- **Message size**: the sizing coefficient is message-size-dependent — encryption overhead as a percentage is likely lower for larger messages
- **Replication factor**: the 1-topic latency and ceiling results ran at RF=3; at that replication factor Kafka's ISR replication creates a per-partition ceiling that sits close to where proxy CPU saturates. The sizing coefficient was derived from RF=1 multi-topic workloads to isolate proxy CPU
- **Horizontal scaling**: linear scaling has been validated across CPU allocations on a single pod; multi-pod scaling hasn't been measured but is expected to follow the same coefficient

The [engineering post](/blog/2026/05/28/benchmarking-the-proxy-under-the-hood/) has the full methodology detail.

---

## Further reading

- [Operator guide: results, methodology, and sizing recommendations](/blog/2026/05/21/benchmarking-the-proxy/) — the full benchmark story for operators
- [Engineering deep dive: tooling, flamegraphs, and what we discovered](/blog/2026/05/28/benchmarking-the-proxy-under-the-hood/) — how we measured it, where the CPU goes, and what surprised us
- [Benchmark quickstart](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-openmessaging-benchmarks/QUICKSTART.md) — run the benchmarks yourself