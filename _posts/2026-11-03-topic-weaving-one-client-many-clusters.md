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

[Post 1]({% post_url 2026-10-12-these-are-not-the-brokers-you-are-connecting-to %}) introduced the Routing API. [Post 2]({% post_url 2026-10-19-connection-switching-identity-without-commitment %}) covered **connection switching** — one client, one cluster, the proxy just picks which one and can change it without the client noticing. [Post 3]({% post_url 2026-10-26-stream-branching-mind-the-gap %}) covered **stream branching** — one client, several clusters, but only one of them is the primary; the rest are shadows the client never directly addresses.

This post is about the third pattern: **topic weaving**. The client is still talking to a single Virtual Kafka Cluster, but what lives behind it is a virtual topic namespace stitched together from topics on several real clusters. Topic A might live on cluster 1, topic B on cluster 2. The router holds the map, fans produce and fetch traffic out to the right cluster, and merges the results back into responses that look like they came from one coherent namespace.

The railway has served us well, but topic weaving needs a different frame. Topic weaving is the sorting office: parcels arrive addressed to a virtual destination and leave down the right chute for their actual one. Unlike stream branching, every cluster on the map accepts produce and fetch requests — there's no shadow, no best-effort copy. That's what gives it a different set of sharp edges.

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
