---
layout: post
title:  "Benchmarking a Kafka proxy: the engineering story"
date:   2026-05-08 00:00:00 +0000
author: "Sam Barker"
author_url: "https://github.com/SamBarker"
categories: benchmarking performance engineering
---

The [first post]({% post_url 2026-05-01-benchmarking-the-proxy %}) covered what we measured and what the numbers mean for operators. This one is for the people who want to know how we measured it, what the flamegraphs actually show, and what we found when we started looking carefully at our own tooling.

## Why not Kafka's own tools?

Kafka ships with `kafka-producer-perf-test` and `kafka-consumer-perf-test`. We'd used them before. The problems:

- **Too noisy**: individual runs produced widely varying results depending on JVM warm-up, scheduling jitter, and GC behaviour. Results were hard to trust and harder to compare across scenarios.
- **Producer-only view**: `kafka-producer-perf-test` gives you publish latency, but nothing about the consumer side. You can't see end-to-end latency — which is what operators actually care about.
- **Awkward to sweep**: running parametric rate sweeps requires scripting around these tools, and comparing results across scenarios requires manual work.

[OpenMessaging Benchmark (OMB)](https://github.com/openmessaging/benchmark) is a better fit. It's an industry-standard tool used by Confluent, the Pulsar team, and others for their published performance comparisons. OMB coordinates producers and consumers across separate worker pods, runs a configurable warmup phase before taking measurements, and outputs structured JSON that's straightforward to process programmatically.

Using OMB also means our numbers are directly comparable to other published Kafka benchmarks — that credibility matters when you're trying to make the case that your proxy doesn't break things.

## What we built on top of OMB

OMB handles the measurement. We built everything around it: deployment, teardown, diagnostics collection, and result processing. All of it lives in `kroxylicious-openmessaging-benchmarks/` in the main repo.

### Helm chart

A Helm chart (`helm/kroxylicious-benchmark/`) deploys the full benchmark stack into Kubernetes:

- OMB coordinator and worker pods
- A Strimzi Kafka cluster
- The Kroxylicious proxy (via the Kroxylicious Kubernetes operator)
- HashiCorp Vault (for the KMS in the encryption scenario)

Scenario-specific configuration lives in `helm/kroxylicious-benchmark/scenarios/` as YAML overrides:

| Scenario file | What it deploys |
|---------------|-----------------|
| `baseline-values.yaml` | Direct Kafka, no proxy |
| `proxy-no-filters-values.yaml` | Proxy with empty filter chain |
| `encryption-values.yaml` | Proxy with AES-256-GCM encryption and Vault |
| `rate-sweep-values.yaml` | Extended run profiles for sweep experiments |

Separating scenarios into override files means the base chart stays stable while each scenario adds only what it needs. Switching between scenarios doesn't require touching the chart itself.

### Orchestration scripts

**`scripts/run-benchmark.sh`** orchestrates a single benchmark run:

1. Deploys the Helm chart for the requested scenario
2. Waits for the OMB Job to complete
3. Collects results: OMB JSON, a JFR recording, an async-profiler flamegraph, and a Prometheus metrics snapshot
4. Tears down

The `--skip-deploy` flag lets you re-run a probe against an already-deployed cluster — essential for rate sweeps where you want to deploy once and probe many times.

**`scripts/rate-sweep.sh`** wraps `run-benchmark.sh` to drive parametric sweeps. It takes `--min-rate`, `--max-rate`, `--step-percent`, and one or more `--scenario` flags. The first probe deploys; subsequent probes use `--skip-deploy`.

### Result processing

Three JBang-runnable Java programs handle result analysis:

- **`RunMetadata.java`**: generates `run-metadata.json` alongside each result. Captures git commit, timestamp, cluster node specs (architecture, CPU, RAM), and — on OpenShift — NIC speed read from the host via the MachineConfigDaemon pod.
- **`ResultComparator.java`**: reads two scenario result directories and produces a markdown comparison table.
- **`ResultSummariser.java`**: reads a rate-sweep result directory and prints a saturation table: target rate, achieved rate, p99, and whether the probe saturated.

Getting NIC speed from a Kubernetes node turned out to be non-trivial — you need host filesystem access to read `/sys/class/net/<iface>/speed`. On OpenShift, the MachineConfigDaemon pods mount the host at `/rootfs`, so we `kubectl exec` into the MCD pod and `chroot /rootfs` to read the speed file without creating any new privileged resources.

## Workload design

The primary workload used **1 topic, 1 partition, 1 KB messages**. This is deliberate. Concentrating all traffic on a single partition pushes things to their limits at lower absolute rates, which makes the proxy overhead easier to isolate: when the system saturates, it's the proxy, not a spread-out broker fleet.

Multi-topic workloads (10 topics, 100 topics) were used to verify that the overhead characteristics hold when load is distributed. At 5,000 msg/sec per topic across 10 topics, every topic-partition pair is well below any saturation point — so what you're measuring is steady-state overhead, not ceiling behaviour.

For throughput ceiling testing we used rate sweeps: start at 34,000 msg/sec, step up by 5% until achieved rate drops below 95% of target. The knee of that curve is the saturation point.

## The flamegraph: where the CPU actually goes

We captured CPU profiles using async-profiler attached to the proxy JVM via `jcmd JVMTI.agent_load`, during the steady-state measurement phase at 36,000 msg/sec. These are self-time percentages — where the CPU is actually spending cycles, not inclusive call-tree time.

The flamegraphs below are fully interactive: hover over a frame to see its name and percentage, click to zoom in, Ctrl+F to search. Scroll within the frame to explore the full stack depth.

### No-filter proxy

<figure>
<iframe src="{{ '/assets/blog/flamegraphs/benchmarking-the-proxy/proxy-no-filters-cpu-profile.html' | relative_url }}"
        width="100%" height="600"
        style="border: 1px solid #ddd; border-radius: 4px;"
        title="CPU flamegraph: no-filter proxy at 36,000 msg/sec">
</iframe>
<figcaption>CPU flamegraph — passthrough proxy (no filters), 36,000 msg/sec, 1 topic, 1 KB messages. <a href="{{ '/assets/blog/flamegraphs/benchmarking-the-proxy/proxy-no-filters-cpu-profile.html' | relative_url }}" target="_blank">Open full screen ↗</a></figcaption>
</figure>

| Category | CPU share |
|----------|-----------|
| Syscalls (send/recv) | 59.2% |
| Native/VM | 16.7% |
| Netty I/O | 10.5% |
| Memory operations | 4.7% |
| JDK libraries | 2.9% |
| Kroxylicious proxy | 1.4% |
| GC | 0.1% |

The proxy is overwhelmingly I/O-bound. 59% of CPU is in `send`/`recv` syscalls — the inherent cost of maintaining two TCP connections (client→proxy, proxy→Kafka) with data flowing through the JVM. The proxy itself accounts for 1.4%. It really is a TCP relay with protocol awareness.

### Encryption proxy (same 36,000 msg/sec rate)

<figure>
<iframe src="{{ '/assets/blog/flamegraphs/benchmarking-the-proxy/encryption-cpu-profile-36k.html' | relative_url }}"
        width="100%" height="600"
        style="border: 1px solid #ddd; border-radius: 4px;"
        title="CPU flamegraph: encryption proxy at 36,000 msg/sec">
</iframe>
<figcaption>CPU flamegraph — encryption proxy (AES-256-GCM), 36,000 msg/sec, 1 topic, 1 KB messages. <a href="{{ '/assets/blog/flamegraphs/benchmarking-the-proxy/encryption-cpu-profile-36k.html' | relative_url }}" target="_blank">Open full screen ↗</a></figcaption>
</figure>

| Category | No-filters | Encryption | Delta |
|----------|-----------|------------|-------|
| Syscalls (send/recv) | 59.2% | 23.5% | −35.7%* |
| Native/VM | 16.7% | 18.9% | +2.2% |
| JCA/AES-GCM crypto | 0.0% | 11.3% | **+11.3%** |
| Memory operations | 4.7% | 10.4% | **+5.8%** |
| JDK libraries | 2.9% | 9.3% | **+6.4%** |
| GC / JVM housekeeping | 0.1% | 5.0% | **+4.9%** |
| Netty I/O | 10.5% | 5.1% | −5.4%* |
| Kafka protocol re-encoding | 0.4% | 3.5% | **+3.1%** |
| Kroxylicious encryption filter | 0.0% | 2.0% | **+2.0%** |

*\* Send/recv and Netty I/O appear to shrink as a percentage share because encryption adds CPU work that grows the total pie. The absolute I/O cost is similar in both scenarios.*

The direct crypto cost is 13.3% (11.3% AES-GCM + 2.0% Kroxylicious filter logic). But encryption adds indirect costs too:

- **Buffer management (+5.8%)**: encrypted records need to be read into buffers, encrypted, and written to new buffers — more allocation, more copying
- **GC pressure (+4.9%)**: more short-lived objects from encryption buffers and crypto operations
- **JDK security infrastructure (+6.4%)**: security provider lookups, key spec handling, parameter generation
- **Kafka protocol re-encoding (+3.1%)**: encrypted records are different sizes and must be re-serialised into Kafka protocol format

Total additional CPU: ~33%. This aligns closely with the ~26% throughput reduction.

If you wanted to optimise this, the highest-impact areas would be: reducing buffer copies (encrypt in-place or use composite buffers), pooling encryption buffers to reduce GC pressure, and caching `Cipher` instances to reduce per-record JDK security overhead.

## The per-connection ceiling

The single-producer encryption ceiling at ~37k msg/sec raised the question of whether that was a per-pod limit or a per-connection limit.

The answer came from a 4-producer rate sweep. Four producers sharing the same partition drove 47k+ msg/sec aggregate through the proxy while proxy CPU held at 570m/1000m — well below pod saturation. The Kafka partition became the bottleneck first.

The explanation: Netty assigns each client connection to its own event loop thread. Encryption happens synchronously on that thread. A single connection is bounded by one event loop's throughput, but additional connections get their own threads. The proxy's aggregate capacity is the sum of its event loop threads' individual capacities — until something else (the Kafka partition, the NIC, pod CPU) saturates first.

Worth noting: with replication factor 3, every message the Kafka leader receives goes out to 2 follower replicas plus potentially one consumer. At 50k msg/sec with 1 KB messages that's ~1.2 Gbps outbound from the leader alone — confirming why the Fyre cluster nodes need 10 Gbps NICs.

## Bugs we found in our own tooling

During the 4-producer rate sweep, we noticed that JFR recordings and flamegraphs from probes 2 onwards all looked identical to probe 1. They were stale copies. Three bugs.

**Bug 1 — wrong JFR settings**: When restarting JFR for a subsequent probe in `--skip-deploy` mode, the script was using `settings=default` instead of `settings=profile`. The default profile omits I/O events including `jdk.NetworkUtilization` — the event we were using to read network throughput from JFR. Fixed to always use `settings=profile`.

**Bug 2 — async-profiler not restarted**: The restart block restarted JFR but never restarted async-profiler. All probes after the first had a flamegraph from probe 1 only.

**Bug 3 — wrong guard variable**: The async-profiler restart was guarded by checking `AGENT_LIB` (the path to the native library). `AGENT_LIB` is always set when the library exists on the image — even when profiling was intentionally skipped on clusters where the `Unconfined` seccomp profile couldn't be applied. The correct guard is `ASYNC_PROFILER_FLAGS`, which is only set when the seccomp patch was successfully applied.

Spotting these required noticing that two different probe flamegraphs were pixel-for-pixel identical, then working back through the restart logic. The lesson: when reusing a deployed cluster across multiple probes, validate that diagnostic collection is actually running fresh for each one.

## The cluster that wouldn't upgrade

Midway through a benchmark campaign, the Fyre OpenShift cluster got stuck mid-upgrade. All 3 worker nodes were `SchedulingDisabled`, meaning benchmark pods couldn't schedule, meaning cluster operators (image-registry, ingress, monitoring, storage) went degraded, which blocked the upgrade from completing.

The root cause was a MachineConfigOperator bug. Each worker's MachineConfigDaemon had finished its upgrade and set `desiredDrain=uncordon-...` — signalling it was ready to be uncordoned — but the MCO never acted on that signal. Workers sat cordoned indefinitely.

Fix: `kubectl uncordon worker0 worker1 worker2`. Once uncordoned, pods scheduled, operators recovered, and the upgrade completed.

Not a Kroxylicious bug, but it cost several hours of cluster recovery time during an active benchmark campaign. Worth knowing about if you're running OCP on Fyre.

## Run it yourself

Everything is in `kroxylicious-openmessaging-benchmarks/` in the [main Kroxylicious repository](https://github.com/kroxylicious/kroxylicious). See `QUICKSTART.md` for step-by-step instructions. You'll need a Kubernetes or OpenShift cluster, the Kroxylicious operator installed, and Helm 3. Minikube works for local runs — the quickstart covers recommended CPU and memory settings.

```bash
# Run a baseline vs encryption comparison
./scripts/run-benchmark.sh --scenario baseline
./scripts/run-benchmark.sh --scenario encryption

# Compare results
jbang src/main/java/io/kroxylicious/benchmarks/results/ResultComparator.java \
  results/baseline results/encryption
```

## What's still open

The gaps we know about and plan to fill:

1. **Connection sweep**: run 1, 2, 4, 8, 16 producers simultaneously at a fixed per-producer rate to characterise the per-pod aggregate ceiling with encryption. The plan is in `CONNECTION-SWEEP-PLAN.md`.

2. **Horizontal scaling**: verify that adding proxy pods scales aggregate throughput linearly.

3. **Multi-partition workloads**: isolate encryption cost without being bounded by Kafka's per-partition ceiling.

4. **Multi-pass sweeps**: each rate point was measured once. Running each probe three times and taking the median would give tighter bounds, particularly in the saturation transition zone.

5. **Message size variation**: larger messages should show lower encryption overhead as a percentage; smaller messages may show higher overhead. 1 KB is a reasonable middle ground but not the whole picture.

The operator-facing sizing reference and all the key tables are in `SIZING-GUIDE.md` in the benchmarks directory.