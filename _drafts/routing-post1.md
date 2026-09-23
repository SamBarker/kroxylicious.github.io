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

That POC has been quietly maturing. We're now in the process of turning it into something you can actually run in production, and in a few weeks we'll be talking about it at [Current in San Francisco](https://current.confluent.io/san-francisco/sessions#session-SESS-165). In a session called *"These are not the brokers you are connecting to"* — my employer does not condone lying, but the proxy will quite happily tell your clients whatever you need it to.

This post is the first in a short series leading up to that talk. The goal here is to establish some vocabulary and get into the gory details I won't have time for onstage. I've been thinking about the design space routing enables and I'm convinced there are a handful of distinct patterns worth naming separately. There are no hard boundaries between the patterns, they all leverage the same underlying infrastructure, but they are distinct because they trade off different aspects of the problem space. The names are mine and while I'll happily accept better ones, we need something to start a conversation (plus I'm right :wink: ).

The deeper dives on each pattern will follow in subsequent posts.

## Pick your poison

If you've tried to migrate a live Kafka workload between clusters, consolidate regional deployments, or shift cloud providers, you will have run into the same core problem: Kafka is not HTTP-based (stop rolling your eyes at the back). Kafka clients are genuinely indifferent to geography — they'll talk to a broker in the same pod just as happily as one in Timbuktu. What they care about, deeply and lastingly, is *which* broker they're talking to. Broker 1 is Broker 1. You can't quietly swap it out, move it between availability zones, or retire it without a lot of fuss. The load balancer doesn't get a say. Most proxies can only manage Kafka as a layer 4 protocol — and layer 4 is BOOOOORRRRING (I will not listen to arguments from the network engineer in the corner).

So when you need to reshape the underlying infrastructure without breaking application teams, you usually end up picking which operational headache you dislike the least.

**Application-level dual writes** look clean in architecture diagrams. In production, network blips cause asymmetric failures, message ordering drifts, and duplicate delivery becomes every application team's problem. Getting twenty teams to deploy matching code changes on the same timeline is an exercise in cat-herding that usually ends with someone's Friday afternoon becoming someone else's out of hours page.

**Replication pipelines** (MirrorMaker 2, et al.) work great for asynchronous backup, but for live consolidation knowing you are in sync is very difficult question, not to mention doubling storage and network costs, and asking consumers to deal with offset translation. You're running twice as much hardware to move bytes you already owned, fine if the migration ever actually ends.

**Maintenance windows** are conceptually simple right up until a legacy service ignores DNS TTLs, holds onto stale sockets, and drops messages silently when the old brokers finally go dark. Sunday 2am is when the core reporting pipeline splutters to a halt.

## What a Layer 7 proxy buys you

Jumping a few layers up the OSI stack to Layer 7 — the Kafka wire protocol itself — changes what's possible. Rather than blindly forwarding bytes, the proxy can inspect, rewrite, and route individual Kafka frames. It knows a `Metadata` response from a `Produce` request. It can answer the client's question about where the brokers are with whatever answer it likes.

Kroxylicious has used the concept of a Virtual Kafka Cluster (VKC) from the start — it's the endpoint clients connect to. What building routing support gave us was a breakthrough — the VKC is more than a networking construct. It's a stable, client-facing identity that we fully control. The brokers behind it can change. The topology behind it can change. The client doesn't need to know.

That shift — from "the VKC is where you point your bootstrap servers" to "the VKC is the contract between the client and whatever we've decided is behind it" — is what opens up the design space this series is exploring. The posts that follow get into the mechanics of each pattern and are honest about where the implementation is today versus where the design points. The talk covers the highlights; the blog is where the details live.

We get it, adding a proxy is operational overhead and we wish as much as you do swapping a CNAME from site A to site B was enough — but as far as Kafka clients are concerned, that's a divorce and why we are all here.

## Name them we must

After reviewing the [routing design proposal](https://github.com/kroxylicious/design/pull/70) and thinking through the problem space, I think there are multiple distinct deployment patterns worth naming. As with all patterns the boundaries are fuzzy and often more than one applies at once. The thing that convinces me they're real is that they have descriptive power — each one has its own tradeoffs, failure modes, and a distinct place on the spectrum from the clear(ish) waters of cluster aliasing to the mangrove swamp of virtual topics. Like all good abstractions, they're useful.

If you're reaching for the [Enterprise Integration Patterns](https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageRoutingIntro.html) book right now — well done for being as old as I am, the rest of you just Googled it. It describes what happens to individual messages, which is interesting, but I'm talking about whole streams. Those patterns are what makes all this possible under the hood; what I'm describing sits a layer or two higher.

The patterns do build on each other in terms of what the proxy has to understand about the Kafka protocol — each one introduces a new class of work the router stage has to own. But the complexity doesn't compound when you compose them, because the routing pipeline is a DAG: each stage is narrowly scoped to its own job and doesn't need to know what the stages around it are doing. A topology-aware routing stage doesn't care whether the topic it's directing traffic to is a virtual topic or a plain one. A virtual topic stage doesn't care whether the cluster it's dispatching to is an alias or a physical cluster. You pay the cost of each stage once, and only if you need it.


### Cluster aliasing

Until recently a VKC provided a 1:1 mapping between the thing the client addressed and the thing the proxy dialled. The routing API breaks that constraint — one VKC can now connect to one or more physical backends, and the target isn't fixed. The VKC is stable; what's behind it doesn't have to be.

*Boom.* A semi truck just drove through the wall of your DC and into your primary cage. What now? Kroxylicious already sits in the client cage — you tell it `VKC_ALPHA` now targets `blue-cluster` instead of `green-cluster`. Done.

This is the Kafka DR dream. So what's new? You could always update a config file and restart. The difference is the failover can now happen in flight — a router that listens to cluster health checks, or one that responds to being paged, can flip the switch without dropping client connections. That was always the easy part though. The hard part is knowing it's safe to do so. *KIP-1279: Cluster Mirroring enters stage left.* By mirroring `green` to `blue` we can trust that when we flip the switch, offset state is intact and it's safe to do so.

Aliasing is more powerful than a dead man's switch though. Consider: you're chasing an issue in the reporting pipeline that only shows up in the sixth hour of the run and nobody can figure out which record trips it up. You've been there, right? What you really want is access to the live data with a debugger. Alas, this job is stuffed full of Personally Identifiable Information — so you're out of luck. You've been there and got *that* t-shirt. What now? You could build a duplication router that shadows production traffic to a staging cluster, piping it through a redaction filter on the way so the PII becomes gibberish. The client never knows. Post 2 gets into the detail.

Before routing, Kroxylicious was a pipe with opinions — it could inspect and rewrite the stream, but it was inherently connection-oriented. One client socket, one backend, straight through. Cluster aliasing breaks the static part of that: the backend can now change. But it's still 1:1.

### Union clusters

Kroxylicious has always been like a cycle courier with opinions — it inspects, rewrites, and has strong views about what is appropriate to carry, but the destination was fixed when the client dropped off the parcel. Routing turns it into a sorting office with standing orders. You write *George Street* on the parcel and drop it at the counter. The sorting office decides whether you mean George Street, Edinburgh or George Street, Dunedin — a city Scottish settlers named after Edinburgh, gave the same street names, and promptly scrambled the layout. (Guess why I know.) The sender doesn't need to know both exist. The brokers behind a union cluster work the same way: they still have to exist somewhere, we're not making them up, but the client only ever sees the one address it was given. Because the proxy controls what gets returned in a metadata response, you decide which brokers are visible, under what names, and what maps where. And we don't need a distributed consensus layer to do it — the Kafka community just spent considerable effort going from two consensus systems down to one with KRaft. Nobody wants a third.

You look after a gaggle of Kafka clusters. You know how they got there. You're not proud of all of them. You can't herd them — geese are worse than cats, they honk back — but you don't have to admit to anyone else how many geese there actually are.

Point your application teams at one VKC and the proxy stitches the backing clusters together into a single cluster view. The client asks for metadata and gets back a broker list. It has no idea that list was assembled from three physical clusters, one of which is on-prem and nobody's quite sure what breed it is. You implement the routing logic — the proxy gives you the framework to dispatch requests to the right place.

Two things to keep in mind. Consumer group co-ordination stays pinned to physical clusters — that's almost always fine, because a group's offset state is tied to the topic-partitions it's consuming and those live on one backend, but it's worth knowing the seam is there. And transactions don't cross cluster boundaries: a transaction that writes to topics on two different backing clusters is two independent transactions whether your code believes that or not. If cross-topic atomicity matters, those topics need to share a physical cluster.

### Virtual topics

A single logical topic whose partitions are composed from physical topics on multiple clusters — which don't even need to share a name. A client asks for metadata for `topic-x` and gets back 32 partitions; partitions 0–15 are sourced from `topic-x` on `us-east`, 16–31 from `topic-eu` on `eu-west`. A `ProduceRequest` for partition 20 gets routed to `eu-west` transparently, with partition numbers rewritten to match the physical layout. The client sees one topic. It has no idea.

The motivating example here is one union clusters can't solve. Your reporting pipeline in `us-east` is hardcoded to read from `topic-x`. It has always read from `topic-x`. It will continue to read from `topic-x`. The problem is on the producer side: your business is growing in Europe, and sending every EU event across the Atlantic to land on the `us-east` cluster is expensive, slow, and fragile. The EU team provisions `topic-eu` on a cluster local to them, sized for their producer load. The router presents both physical topics as one logical `topic-x` to every client. EU producers write locally. The reporting pipeline reads the full partition space without a config change. Nobody crosses the Atlantic unnecessarily.

What the proxy has to do here is more demanding than in any of the previous patterns: partition numbers must be rewritten consistently across every Kafka RPC that mentions them — `Metadata`, `Produce`, `Fetch`, `OffsetCommit`, `OffsetFetch`, `ListOffsets`, group coordinator lookups. That's the essential complexity of the pattern, not incidental overhead. It's a lot of surfaces to get right. The operational contract also shifts: both physical topics have to honour the mapping, and the router config is now the source of truth for what `topic-x` means. Transactions don't cross cluster boundaries here either — same caveat as union clusters, but worth repeating because with virtual topics it's easier to forget the seam is there.

---

These three patterns give us a working vocabulary for the rest of the series. The posts that follow take each one in turn — what it can do, what it can't, and why. Some of the limits are ours and will close over time. Some are the Kafka protocol's: transactions have no external coordinator, and no amount of clever routing changes that. And some would require the proxy to grow a consensus layer of its own — which is a whole different animal, and not one we're planning to domesticate any time soon.

If you're thinking about Kafka topology problems, have a use case that doesn't fit cleanly into any of these patterns, or want to tell us where the vocabulary breaks down — find us on [GitHub](https://github.com/kroxylicious/kroxylicious), [Slack](https://kroxylicious.slack.com), or [Bluesky](https://bsky.app/profile/kroxylicious.io).
