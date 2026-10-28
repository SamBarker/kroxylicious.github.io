---
layout: post
title: "Topic Weaving: One client, many clusters"
date: 2026-11-03 15:00:00 +1200
author: "Sam Barker"
author_url: "https://github.com/sambarker"
# noinspection YAMLSchemaValidation
categories: blog kroxylicious-proxy
tags: [ "routing" ]
---

[Post 1]({% post_url 2026-10-12-these-are-not-the-brokers-you-are-connecting-to %}) introduced the Routing API. [Post 2]({% post_url 2026-10-19-connection-switching-identity-without-commitment %}) covered **connection switching** — one client, one cluster, the proxy just picks which one. [Post 3]({% post_url 2026-10-26-stream-branching-mind-the-gap %}) covered **stream branching** — one client, one primary cluster, with the router silently fanning writes to shadow clusters the client never knows about.

This post is about the third pattern: **topic weaving**. Connection switching and stream branching both treat the cluster as the unit of routing — you're deciding *where* traffic lands, not *which topics* the client is allowed to see. Topic weaving is different. The client still connects to a single Virtual Kafka Cluster, but the namespace behind it is stitched together from topics distributed across several real clusters. Topic A lives on cluster 1, topic B lives on cluster 2; the router holds the map and the client never has to know.

Kafka clusters accumulate. Teams get their own cluster for isolation, another spins up for a different region, a third appears because somebody hit a partition limit and it was quicker to provision hardware than fight for headroom. The data teams feel it first: every pipeline that crosses a cluster boundary needs its own bootstrap config, its own credentials, its own mental model of which topic lives where. A data engineer building a join across two domains has to know which physical cluster each topic lives on — not because it's relevant to their problem, but because Kafka makes it unavoidable. Topic weaving moves that knowledge into a routing layer where the platform team can encode it once — and control which applications can see which topics while they're at it.

The railway metaphor has served us well but it runs out of track here. Think of a sorting office instead. Parcels arrive addressed to a virtual destination — `orders`, `payments`, `inventory` — and the sorter routes each one down the right chute to its actual cluster. Every backing cluster is a peer — every write counts. That's also why there are sharp edges. A transaction requires a coordinator, and a coordinator can only see its own cluster. If you need to write atomically to `orders` and `inventory` and they live on different clusters, the sorting office can't help you.

## TODO

- [x] Introduction: what the sorting office does that the railway station didn't
- [ ] Refresher: how the existing patterns are different (what the client knows, what it doesn't)
- [ ] The topic map: how the router decides which topic lives where
- [ ] The client's view: Metadata, ListTopics, and the virtual namespace
- [ ] Producing: why node ID translation isn't enough, and why PID translation is hard
  - Pull in stash from `stash-replica-routing.md` — "why PIDs aren't node IDs"
- [ ] Consuming: the simpler side — passing upstream PIDs through, `read_committed` caveats
- [ ] Transactions: the coordinator lives on one cluster, and that's all
  - Reference Post 3's transactions section; explain how weaving makes it worse
- [ ] KIP-939 and why it isn't magic
  - Link/summarise the Gemini doc before quoting
- [ ] Proxy placement: run it in the client's network/trust zone, not co-located with any single cluster, so a cluster failure doesn't take the proxy with it
- [ ] When to use weaving vs replication vs connection switching
- [ ] Closing: what's next in the series

---

*Stash and working notes follow below — remove before publishing.*

---

<!-- stash: PID vs node ID argument (from stash-replica-routing.md) -->
<!-- stash: weaving produce/consume PID treatment -->
<!-- stash: KIP-939 note -->
