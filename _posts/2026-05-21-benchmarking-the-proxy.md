---
layout: post
title:  "Does my proxy look big in this cluster?"
date:   2026-05-21 00:00:00 +0000
author: "Sam Barker"
author_url: "https://github.com/SamBarker"
categories: benchmarking performance
---

All good benchmarking stories start with a hunch. Mine was that Kroxylicious is cheap to run — I'd stake my career on it, in fact — but it turns out that "trust me, I wrote it" is not a widely accepted unit of measurement. People want proof. Sensibly.

There's a practical question underneath the hunch too. The most common thing operators ask us is some variation of: "How many cores does the proxy need?" Which is really just "is this thing going to slow down my Kafka?" in a polite engineering hat. We'd been giving the classic answer: "it depends on your workload and traffic patterns, so you'll need to test in your environment." Which is true. And also deeply unsatisfying for everyone involved, including us.

So we stopped saying "it depends", and got off the fence: we built something you can run **yourselves** on your own infrastructure with your own workload, and measured it. Here are some representative numbers from ours.

## What we measured

We ran three scenarios against the same Apache Kafka® cluster on the same hardware:

- **Baseline** — producers and consumers talking directly to Kafka, no proxy in the path
- **Passthrough proxy** — traffic routed through Kroxylicious with no filter chain configured
- **Record encryption** — traffic through Kroxylicious with AES-256-GCM record encryption enabled, using HashiCorp Vault as the KMS

We used [OpenMessaging Benchmark (OMB)](https://github.com/openmessaging/benchmark) rather than Kafka's own `kafka-producer-perf-test`. OMB is an industry-standard tool that coordinates producers and consumers together, measures end-to-end latency (not just publish latency), and produces structured JSON that makes comparison straightforward. More on why we built a whole harness around it in the [companion engineering post]({% post_url 2026-05-28-benchmarking-the-proxy-under-the-hood %}).

## Test environment

No, we didn't run this on a laptop — it's a realistic deployment: a 6-node OpenShift cluster on Fyre, IBM's internal cloud platform — a controlled environment. Kroxylicious ran as a single proxy pod with a 1000m CPU limit.

| Component | Details |
|-----------|---------|
| CPU | AMD EPYC-Rome, 2 GHz |
| Cluster | 6-node OpenShift, RHCOS 9.6 |
| Kafka | 3-broker Strimzi cluster, replication factor 3 |
| Kroxylicious | 0.20.0, single proxy pod, 1000m CPU limit |
| KMS | HashiCorp Vault (in-cluster) |

The primary workload used 1 topic, 1 partition, 1 KB messages. We chose single-partition deliberately: it concentrates all traffic on one broker, so you hit ceilings quickly and any proxy overhead is easy to isolate. We also ran 10-topic and 100-topic workloads to make sure the results hold when load is spread more realistically across brokers.

One important caveat: this Kafka cluster is deliberately untuned. We're not trying to squeeze every message-per-second out of Kafka — we're using it as a fixed baseline to measure what the proxy adds on top. Kafka experts will find obvious headroom to improve on our baseline numbers; that's fine and expected. The deltas are what matter here, not the absolutes.

---

## The passthrough proxy: negligible overhead

Good news first. The proxy itself — with no filter chain, just routing traffic — adds almost nothing.

**10 topics, 1 KB messages (5,000 msg/sec per topic):**

| Metric | Baseline | Proxy | Delta |
|--------|----------|-------|-------|
| Publish latency avg | 2.62 ms | 2.79 ms | +0.17 ms (+7%) |
| Publish latency p99 | 14.09 ms | 15.17 ms | +1.08 ms (+8%) |
| E2E latency avg | 94.87 ms | 95.34 ms | +0.47 ms (+0.5%) |
| E2E latency p99 | 185.00 ms | 186.00 ms | +1.00 ms (+0.5%) |
| Publish rate | 5,002 msg/s | 5,002 msg/s | 0 |

**100 topics, 1 KB messages (500 msg/sec per topic):**

| Metric | Baseline | Proxy | Delta |
|--------|----------|-------|-------|
| Publish latency avg | 2.66 ms | 2.82 ms | +0.16 ms (+6%) |
| Publish latency p99 | 5.54 ms | 6.07 ms | +0.53 ms (+10%) |
| E2E latency avg | 253.16 ms | 253.76 ms | +0.60 ms (+0.2%) |
| E2E latency p99 | 499.00 ms | 499.00 ms | 0 |
| Publish rate | 500 msg/s | 500 msg/s | 0 |

**The headline: ~0.2 ms additional average publish latency. Throughput is unaffected.**

What did I take away from this entirely unsurprising result? Not much, honestly — without filters the proxy is little more than a couple of hops through the TCP stack, but we now have data rather than a hunch.      
The end-to-end (E2E) p99 figure is dominated by the Kafka consumer fetch timeouts, as it should be. That said, it is reassuring to have a sub-ms impact on the p99.

---

## Record encryption: now we're doing real work

Ok, so let's make the proxy smarter — make it do something people actually care about! [Record encryption](https://kroxylicious.io/documentation/0.20.0/html/record-encryption-guide) uses AES-256-GCM to encrypt each record passing through the proxy. AES-256-GCM is going to ask the CPU to work relatively hard on its own, but it's also going to push the proxy to understand each record it receives, unpack it, copy it, encrypt it, and re-pack it before sending it on to the broker. With all that work going on we expect some impact to latency and throughput. To answer our original question we need to identify two things: the latency when everything is going smoothly, and the reduction in throughput all this work causes. Monitoring latency once we go past the throughput inflection point isn't very helpful — it's dominated by the throughput limits and their erratic impacts on the latency of individual requests (a big hello to batching and buffering effects).

### Latency at sub-saturation rates

A quick note on percentiles for anyone not steeped in performance benchmarking: p99 latency is the value that 99% of requests complete within — meaning 1 in 100 requests takes longer. Averages flatter; the p99 is what your slowest clients actually experience, and it's usually the number that matters.

So we know encryption is doing a lot of work, but to find out the real impact we need to compare it to a plain Kafka cluster (and yes, people do run Kroxylicious without filters — TLS termination, stable client endpoints, virtual clusters — but that's a different post). The table below tells us that above a certain inflection point the numbers get really, really noisy — especially in the p99 range.

**1 topic, 1 KB messages — baseline vs encryption:**

| Rate | Metric | Baseline | Encryption | Delta |
|------|--------|----------|------------|-------|
| 34,000 msg/s | Publish avg | 8.00 ms | 8.19 ms | +0.19 ms (+2%) |
| 34,000 msg/s | Publish p99 | 48.65 ms | 64.01 ms | +15.35 ms (+32%) |
| 36,000 msg/s | Publish avg | 9.38 ms | 10.46 ms | +1.08 ms (+12%) |
| 36,000 msg/s | Publish p99 | 63.92 ms | 88.98 ms | +25.06 ms (+39%) |
| 37,200 msg/s | Publish avg | 9.12 ms | 12.19 ms | +3.07 ms (+34%) |
| 37,200 msg/s | Publish p99 | 74.88 ms | 113.15 ms | +38.27 ms (+51%) |

So we know that somewhere above 34k we're hitting a limit. Time to hunt out exactly where — enter the rate-sweep.

### Throughput ceiling

A rate-sweep is exactly what it sounds like: pick a starting rate, let OMB run long enough to get a stable measurement, then step up by a fixed percentage and repeat until the system can't keep up. We defined "can't keep up" as the sustained throughput dropping by more than 5% below the target rate — at that point, something has saturated.

We started at 34k (right where the latency table started getting interesting) and stepped up in 5% increments. The results:

- **Baseline**: sustained up to ~50,000–52,000 msg/sec (the ceiling we observed on our test cluster)
- **Encryption**: sustained up to **~37,200 msg/sec**, then started intermittently saturating
- **Cost: approximately 26% fewer messages per second per partition**

The transition wasn't a clean cliff edge — between 37,600 and 42,000 msg/sec the proxy alternated between sustaining and saturating. That pattern is characteristic of running right at a limit: it's not that it suddenly falls over, it's that small fluctuations (GC pauses, scheduling jitter) are enough to tip it either way. Above ~39,000 msg/sec, p99 latency regularly spiked above 1,700 ms. Stay below 37k and you're fine. Creep above it and you'll notice. The numbers are not absolute — they are just what we measured on our cluster; your mileage **will vary**.

### The ceiling scales with CPU budget

The fact the proxy is low latency didn't surprise me, but this did — and it matters when we think about scaling. We maxed out a single connection, but that didn't mean we'd maxed out the proxy.

Once we had the single-producer encryption ceiling at ~37k msg/sec, the obvious question was: is that the limit for the whole proxy pod, or just for one connection? We ran the same test with 4 producers. With 4 connections the proxy sustained well past the single-producer ceiling — proxy CPU had headroom to spare, and Kafka's partition became the bottleneck first.

Going further: we swept the same workload at 1000m, 2000m, and 4000m CPU. The throughput ceiling scaled linearly with the CPU budget — 1000m at ~40k msg/sec, 2000m at ~80k, 4000m at ~160k. The proxy isn't hitting a fixed architectural wall; it's hitting a CPU budget wall, and that wall moves when you give it more CPU.

**The practical implication**: the throughput ceiling is not a fixed number — it's a function of the CPU you allocate. Set `requests` equal to `limits` in your pod spec; this makes the CPU budget deterministic and the ceiling predictable. The companion engineering post has the full story of how we found this, including the workload design choices needed to isolate proxy CPU from Kafka's own limits.

---

## Sizing guidance

Numbers without guidance aren't very useful, so here's how to translate these results into pod specs.

**Passthrough proxy**: size your Kafka cluster as you normally would. The proxy won't be the bottleneck — but if you want to verify that on your own hardware, the rate sweep is exactly the tool for it. Run the baseline and passthrough scenarios back-to-back and you'll have your own numbers.

**With record encryption:**

1. **Throughput budget**: encryption imposes a CPU-driven throughput ceiling. As a planning formula:

   > **`proxy CPU (millicores) = 20 × produce throughput (MB/s)`**

   Add ×1.3 headroom for GC pauses and burst. This assumes matched consumer load (1:1 produce:consume) and was measured on AMD EPYC-Rome 2 GHz with AES-NI — calibrate on your own hardware using the rate sweep.

   Worked example: 100k msg/s at 1 KB = 100 MB/s produce → 100 × 20 = 2000m, plus headroom → ~2600m (~2.6 cores).

2. **Latency budget**: well below saturation, expect 0.2–3 ms additional average publish latency and 15–40 ms additional p99. The overhead scales with how hard you're pushing — give yourself headroom and you'll barely notice it.

3. **Scaling**: set `requests` equal to `limits` in your pod spec — this makes the CPU budget deterministic, which makes the throughput ceiling predictable. To increase throughput, raise the CPU limit. For redundancy, add proxy pods.

4. **KMS overhead**: DEK caching means Vault isn't on the hot path for every record. Our tests triggered only 5–19 DEK generation calls per benchmark run. The KMS is not the thing to worry about.

---

## Caveats and next steps

These are real results from real hardware, but they don't tell a story for your workload. A few things worth knowing before you put these numbers in a slide deck:

- **Message size**: all results use 1 KB messages. The coefficient is message-size-dependent — encryption overhead as a percentage is likely lower for larger messages.
- **Replication factor**: the 1-topic rate sweep ran at RF=3. At that replication factor, Kafka's ISR replication traffic creates a per-partition ceiling that sits close to where proxy CPU also saturates — the two limits are entangled in those results. The sizing coefficient was derived from RF=1 multi-topic workloads specifically to isolate proxy CPU. The [companion engineering post]({% post_url 2026-05-28-benchmarking-the-proxy-under-the-hood %}) has that detail.
- **Horizontal scaling**: linear scaling has been validated across CPU allocations on a single pod; multi-pod horizontal scaling hasn't been measured but is expected to follow the same coefficient.

For the engineering story — why we built a custom harness on top of OMB, what the CPU flamegraphs actually show, and the bugs we found in our own tooling along the way — that's in the [companion post]({% post_url 2026-05-28-benchmarking-the-proxy-under-the-hood %}).

The full benchmark suite, quickstart guide, and sizing reference are in `kroxylicious-openmessaging-benchmarks/` in the [main Kroxylicious repository](https://github.com/kroxylicious/kroxylicious).
