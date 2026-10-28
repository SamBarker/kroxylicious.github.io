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

[Post 1]({% post_url 2026-10-12-these-are-not-the-brokers-you-are-connecting-to %}) introduced the Routing API and named the patterns. [Post 2]({% post_url 2026-10-19-connection-switching-identity-without-commitment %}) covered **connection switching** — the router picks a cluster at connect time. [Post 3]({% post_url 2026-10-26-stream-branching-mind-the-gap %}) covered **stream branching** — the router fans traffic across multiple clusters, but the client only knows about one of them.

This is the fourth post: **topic weaving**. The client knows about all of the clusters. It isn't running a simple point-to-point stream anymore — it's producing to and consuming from topics that are scattered across several physical clusters, and it knows some of those clusters exist. What the proxy supplies is the illusion that those clusters are one coherent thing: a single set of topic names, a single set of offsets, a single authentication handshake.

## TODO

- [ ] Introduction: what the sorting office does that the railway station didn't
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
