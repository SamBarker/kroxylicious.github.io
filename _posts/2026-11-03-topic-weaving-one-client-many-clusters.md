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

This is the fourth post in a series about routing in Kroxylicious. [Post 1]({% post_url 2026-10-12-these-are-not-the-brokers-you-are-connecting-to %}) introduced the Routing API and named four patterns for using it: [connection switching]({% post_url 2026-10-19-connection-switching-identity-without-commitment %}), [stream branching]({% post_url 2026-10-26-stream-branching-mind-the-gap %}), topic weaving and partition weaving. This post covers the third, **topic weaving**.

Kafka clusters accumulate. Teams get their own cluster for isolation, another spins up for a different region, a third appears because somebody hit a partition limit and it was quicker to provision hardware than fight for headroom. The data teams feel it first: every pipeline that crosses a cluster boundary needs its own bootstrap config, its own credentials, its own mental model of which topic lives where. A data engineer building a join across two domains has to know which physical cluster each topic lives on — not because it's relevant to their problem, but because Kafka makes it unavoidable.

## A cluster is whatever the metadata says it is

A Kafka client starts with a list of bootstrap addresses and picks one to talk to. It sends a `Metadata` request there and gets back a list of brokers, the topics it asked about, and for every partition of those topics, the broker that leads it. From then on it connects directly to those brokers and sends each request to the right one. Everything the client believes about the cluster comes from that one response.

The proxy sits in the middle and speaks Kafka, so it gets to write that response. A Virtual Kafka Cluster (VKC) is the stable address clients connect to, and until recently all the proxy did with the response was swap the broker addresses for its own. The brokers and topics still came from one real cluster. The Routing API changes who answers. It lets a router, a component you plug into the proxy, decide where each request goes and build the response from whatever it likes. The proxy supplies the plumbing; the router supplies the policy. Nothing says the answers have to come from the same cluster, and the client takes the response at face value.

That's topic weaving. The client connects to a single VKC, but the namespace behind it is stitched together from topics on several real clusters. Topic A lives on cluster 1, topic B lives on cluster 2, and the router holds the map. Connection switching and stream branching both treat the cluster as the unit of routing: you're deciding *where* traffic lands. Weaving decides *which topics* exist, where they live, and which applications can see them. The platform team encodes that once, in the routing layer, instead of every pipeline carrying its own copy.

The railway metaphor has served us well but it runs out of track here. Think of a sorting office instead. Parcels arrive addressed to a virtual destination — `orders`, `payments`, `inventory` — and the sorter routes each one down the right chute to its actual cluster. Every backing cluster is a peer — every write counts. That's also why there are sharp edges. A transaction requires a coordinator, and a coordinator can only see its own cluster. If you need to write atomically to `orders` and `inventory` and they live on different clusters, the sorting office can't help you.

## What the client knows

A VKC already keeps the real cluster from the client: clients dial the proxy, never the brokers. What the patterns change is what stands behind that address, and how much of it the client can see.

**Connection switching** makes the choice of cluster dynamic. The client still sees one cluster. The proxy can change which real one is behind it.

**Stream branching** adds connections the client never sees. They may go to other clusters, or to another topic or broker on the same one. The client has one stream, and nothing is allowed to break that.

**Topic weaving** hides the *seams*. The `MetadataResponse` lists brokers from every backing cluster. The client connects to all of them (via the proxy!), sends them requests, and takes their answers at face value. It just believes they belong to one cluster.

The client really is talking to several clusters. Some of what it carries with it, like a producer ID or an open transaction, was issued by one cluster and means nothing to the others. How much that matters depends on what you're doing with it.

## TODO

- [x] Introduction: what the sorting office does that the railway station didn't
- [x] Refresher: how the existing patterns are different (what the client knows, what it doesn't)
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
