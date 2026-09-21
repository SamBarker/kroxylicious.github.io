---
layout: post
title: "These are not the brokers you are connecting to"
date: 2026-09-04 15:00:00 +1200
author: "Sam Barker"
author_url: "https://github.com/sambarker"
# noinspection YAMLSchemaValidation
categories: blog kroxylicious-proxy
tags: [ "routing" ]
---

Back in May, Tom wrote about [a proof of concept for routing]({% post_url 2026-05-21-topic-routing %}) — Kafka clients producing and consuming from topics scattered across multiple clusters, with no idea that's what they're doing. The proxy handles the fan-out, the response merging, the session state. The client just sees topics.

That POC has been quietly maturing. We're now in the process of turning it into something you can actually run in production, and in a few weeks we'll be talking about it at [Current in San Francisco](https://current.confluent.io/). The talk is called *"These are not the brokers you are connecting to"*, which felt like the honest description of what the proxy is doing.

This post is the first in a short series leading up to that talk. The goal here is to establish some vocabulary — I've been thinking about the routing design space and I'm convinced there are a handful of distinct patterns worth naming separately, because each one carries different tradeoffs and breaks down in different ways. The names are mine and I'll happily accept better ones, but I think having *something* to call them makes it easier to reason about the problems without conflating them.

The deeper dives on each pattern will follow in subsequent posts.

## Pick your poison

If you've tried to migrate a live Kafka workload between clusters, consolidate regional deployments, or shift cloud providers, you know the bottom line: Kafka clients are remarkably opinionated about where their brokers live. They don't just talk to a virtual endpoint — they demand exact broker metadata, explicit partition assignments, and direct TCP connections to specific physical nodes. You can't just update a load balancer and go home.

So when you need to reshape the underlying infrastructure without breaking application teams, you usually end up picking which operational headache you dislike the least.

**Application-level dual writes** look clean in architecture diagrams. In production, network blips cause asymmetric failures, message ordering drifts, and duplicate delivery becomes every application team's problem. Getting twenty teams to deploy matching code changes on the same timeline is an exercise in cat-herding that usually ends with someone's Friday afternoon becoming someone else's Saturday morning.

**Replication pipelines** (MirrorMaker 2, et al.) work fine for asynchronous backup, but for live consolidation you're adding latency, doubling storage and network costs, and asking consumers to deal with offset translation. You're running twice as much hardware to move bytes you already owned.

**Maintenance windows** are conceptually simple right up until a legacy service ignores DNS TTLs, holds onto stale sockets, and drops messages silently when the old brokers finally go dark. Sunday 2am is a fine time for this to happen.

## What a Layer 7 proxy buys you

Intercepting at Layer 7 — the Kafka wire protocol itself — is the alternative. The proxy sits between clients and brokers, inspects and rewrites Kafka frames, and presents whatever cluster topology it wants to clients regardless of what's actually behind it. Clients connect to a virtual cluster. What they get told about that cluster is up to us.

To be clear about the tradeoffs: an L7 proxy adds a network hop, consumes CPU for frame inspection and rewriting, and gives you another piece of infrastructure to keep alive. If a DNS CNAME swap actually solves your problem, do that instead. But when you need to decouple what clients see from how your physical infrastructure is actually laid out, this is the lever.

## Four patterns (working names)

After reviewing the [routing design proposal](https://github.com/kroxylicious/design/pull/70) and thinking through the problem space, I think there are four distinct patterns worth naming. They're not mutually exclusive and they compose, but each one has its own failure modes, so it helps to be able to talk about them separately.

### Cluster aliasing

A static virtual cluster endpoint maps to one physical backend, but the mapping can be changed at the proxy layer without touching clients.

Clients connect to `kafka-virtual.company.internal`. The proxy maps their connections to `cluster-blue`. When you want to migrate to `cluster-green`, you update the proxy config. Clients never reconnect, never need new bootstrap addresses, never need to know a migration happened.

The catch is that this only solves connectivity. Flipping the pointer without replicating state means consumers hit offset mismatches on the new cluster. The routing layer isn't magic — it's just decoupling one specific piece of the problem. In Post 2 we'll look at pairing this with KIP-1279 to handle the state problem, which makes this pattern actually useful for DR rather than just theoretically interesting.

### Union clusters

Multiple distinct physical clusters exposed through a single virtual cluster endpoint. The proxy synthesises a unified metadata view — to a producer or consumer it looks like one cluster. Behind the scenes, `orders-*` topics route to a high-throughput cluster, `analytics-*` topics go to a cheaper storage-optimised one.

The obvious failure mode is namespace collisions. If `orders-v1` exists on two backends, the proxy has to pick a winner or enforce prefix rules. We haven't pushed the metadata synthesis hard enough at scale yet to characterise the memory behaviour at tens of thousands of topics across many backends — worth flagging if that's your situation.

### Union topics

A single logical topic whose partitions are sharded across multiple physical clusters. A client asks for metadata for `events` with 32 partitions; partitions 0–15 live on Cluster A, 16–31 on Cluster B. A `ProduceRequest` for partition 20 gets routed to Cluster B transparently.

The hard limit today: transaction coordinator boundaries break across physical clusters. If you're relying on multi-topic transactions or read-committed isolation, splitting a topic across cluster boundaries removes those guarantees. This pattern is a good fit for simple, independently partition-keyed workloads. For anything transactional, wait.

### Topology-aware routing

Traffic directed dynamically based on client metadata or locality — the main use case being cross-AZ bandwidth costs, which have a habit of appearing as a surprise line item in cloud bills. The proxy reads rack attributes or client IP blocks and routes fetch requests to brokers inside the same availability zone.

The failure mode here is proxy placement. A client in `us-east-1a` hitting a proxy in `us-east-1b` that forwards to a broker in `us-east-1a` doubles your cross-AZ cost instead of eliminating it. The proxy fleet has to be co-located with clients for the locality savings to materialise.

---

These four patterns give us a working vocabulary for the rest of the series. They're not all at the same maturity level — cluster aliasing and union topics are closest to production-ready, topology-aware routing is further out — and the posts that follow will be honest about where the code is versus where the design points.

Next up: **Active-Passive DR with cluster aliasing and KIP-1279**. Fair warning: this one is going to live as a POC on a branch rather than shipped code, but it's what we're demoing at Current and the mechanics are worth understanding on their own terms.

If you're thinking about Kafka topology problems, have a use case that doesn't fit cleanly into any of these patterns, or want to tell us where the vocabulary breaks down — find us on [GitHub](https://github.com/kroxylicious/kroxylicious), [Slack](https://kroxylicious.slack.com), or [Bluesky](https://bsky.app/profile/kroxylicious.io).
