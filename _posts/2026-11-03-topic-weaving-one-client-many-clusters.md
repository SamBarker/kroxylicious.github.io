---
layout: post
title: "Topic Weaving: One client, many clusters"
date: 2026-11-03 15:00:00 +1300
author: "Sam Barker"
author_url: "https://github.com/sambarker"
# noinspection YAMLSchemaValidation
categories: blog kroxylicious-proxy
tags: [ "routing" ]
---

This is the fourth post in a series about routing in Kroxylicious. [Post 1]({% post_url 2026-10-12-these-are-not-the-brokers-you-are-connecting-to %}) introduced the Routing API and named four patterns for using it: [connection switching]({% post_url 2026-10-19-connection-switching-identity-without-commitment %}), [stream branching]({% post_url 2026-10-26-stream-branching-mind-the-gap %}), topic weaving and partition weaving. This post covers the third, **topic weaving**.

Kafka clusters accumulate. Teams get their own cluster for isolation, another spins up for a different region, a third appears because somebody hit a partition limit and it was quicker to provision hardware than fight for headroom. The data teams feel it first: every pipeline that crosses a cluster boundary needs its own bootstrap config, its own credentials, its own mental model of which topic lives where. A data engineer building a join across two domains has to know which physical cluster each topic lives on — not because it's relevant to their problem, but because Kafka makes it unavoidable.

## A cluster is whatever the metadata says it is

A Kafka client starts with a list of bootstrap addresses and picks one to talk to. It sends a `Metadata` request there and gets back a list of brokers, the topics it asked about, and for every partition of those topics, the broker that leads it. From then on it connects directly to those brokers and sends each request to the right one. Everything the client believes about the cluster comes from `Metadata` responses.

The proxy sits in the middle and speaks Kafka, so it gets to write that response. A Virtual Kafka Cluster (VKC) is the stable address clients connect to, and until recently all the proxy did with the response was swap the broker addresses for its own. The brokers and topics still came from one real cluster. The Routing API changes who answers. It lets a router, a component you plug into the proxy, decide where each request goes and build the response from whatever it likes. The proxy supplies the plumbing; the router supplies the policy. Nothing says the answers have to come from the same cluster, and the client takes the response at face value.

That's topic weaving. The client connects to a single VKC, but the namespace behind it is stitched together from topics on several real clusters. Topic A lives on cluster 1, topic B lives on cluster 2, and the router holds the map. Connection switching and stream branching both treat the cluster as the unit of routing: you're deciding *where* traffic lands. Weaving decides *which topics* exist, where they live, and which applications can see them. The platform team encodes that once, in the routing layer, instead of every pipeline carrying its own copy.

The railway metaphor has served us well but it runs out of track here. Think of a sorting office instead. Parcels arrive addressed to a virtual destination — `orders`, `payments`, `inventory` — and the sorter routes each one down the right chute to its actual cluster. Every backing cluster is a peer — every write counts. That's also why there are sharp edges. A transaction requires a coordinator, and a coordinator can only see its own cluster. If you need to write atomically to `orders` and `inventory` and they live on different clusters, the sorting office can't help you.

## What the client knows

A VKC already keeps the real cluster from the client: clients dial the proxy, never the brokers. What the patterns change is what stands behind that address, and how much of it the client can see.

**Connection switching** makes the choice of cluster dynamic. The client still sees one cluster. The proxy can change which real one is behind it.

**Stream branching** adds connections the client never sees. They may go to other clusters, or to another topic or broker on the same one. The client has one stream, and nothing is allowed to break that.

**Topic weaving** hides the *seams*. The `MetadataResponse` lists brokers from every backing cluster. The client connects to all of them (via the proxy!), sends them requests, and takes their answers at face value. It just believes they belong to one cluster.

The client really is talking to several clusters. Some of what it carries with it, like a producer ID or an open transaction, was issued by one cluster and means nothing to the others. How much that matters depends on what you're doing with it.

## Transactions stop at the cluster boundary

A transactional producer starts by sending `FindCoordinator` for its `transactional.id`, then `InitProducerId` to whichever broker the answer names. From then on that coordinator tracks the transaction, and when the producer commits it writes the commit or abort markers to the partitions involved. The coordinator, its transaction log and those markers all belong to one cluster.

A coordinator can only see its own cluster, so the obvious answer is to give the client one everywhere. The router fans `InitProducerId` out to every backing cluster and starts a transaction on each. As the client registers partitions and produces, the router sends each call to the cluster that owns the topic, using the producer ID and epoch that cluster issued. The client holds one producer ID and the router holds the mapping to the rest. That mapping has to survive a router restart and be visible to every proxy instance, so it needs a state store. That's real work, but it's work you can do.

It falls over at commit. The client sends one `EndTxn` and the router has to turn it into one per cluster. On each cluster, commit is a point of no return: once the coordinator has written its decision, it will commit, whatever else happens. Until then it is free to refuse, and each cluster decides for itself. Cluster 1 can pass the point of no return while cluster 2 says no. None of the ways cluster 2 can say no are transient. The transaction may have timed out, since each cluster runs its own clock from the first partition added there. A zombie may have bumped the producer epoch. The ACLs may differ. Then `orders` has its records and `inventory` doesn't, and whatever the client is told is wrong for one of them.

A state store doesn't rescue this. It can remember that the router meant to commit cluster 2, but it can't make cluster 2 agree. Reordering the commits doesn't help either, because whichever goes first can't be undone.

So stop negotiating and pick a boss. One cluster is the primary, and its coordinator runs every transaction. The client's `InitProducerId`, `AddPartitionsToTxn` and `EndTxn` all go there, while the records still go to whichever cluster owns the topic. Commit is now a single decision on a single coordinator, so the atomicity problem is gone.

It doesn't survive the first write to another cluster. The client registers each partition with the coordinator before it writes to it, and the primary's coordinator doesn't recognise `inventory`'s partitions, because they aren't in its cluster. It refuses them, and the transaction never gets as far as commit.

Both attempts fail for the same reason. Somewhere there has to be a moment when every cluster has promised to commit before any of them does, and Kafka's transaction protocol has no such step.

## KIP-939 might add the missing step

[KIP-939](https://cwiki.apache.org/confluence/display/KAFKA/KIP-939%3A+Support+Participation+in+2PC) is the obvious objection. It's accepted, it's about two-phase commit, and it has not landed in Kafka yet. It lets Kafka take part in somebody else's two-phase commit: a producer can prepare a transaction, and a prepared transaction isn't aborted by the timeout while it waits for an external coordinator to decide. That is the promise our two attempts were missing.

In principle the router could be that coordinator. It would start a transaction on each backing cluster, wait for all of them to prepare, record the decision, and then tell each one to commit. The client would still believe it was talking to a single coordinator. The hard part is the middle step. Someone has to durably record the decision between "everyone prepared" and "everyone committed", and survive a crash in the gap. A router that does that needs a durable log of its own, recovery after a restart, and a way to stop two proxy instances disagreeing about the outcome. That is the consensus layer from [post 1]({% post_url 2026-10-12-these-are-not-the-brokers-you-are-connecting-to %}), and the Kafka community has just spent years moving from ZooKeeper to KRaft so that nobody has to run a second consensus system alongside Kafka. Asking a proxy to bring its own would be a step backwards.

That said, this is where a boss cluster might earn its keep. Pick one cluster to hold the router's state, and keep the decision log in a compacted topic on it. Kafka already gives you durable, replicated storage there, with nothing new to deploy. The recovery logic is still yours to write. We haven't investigated this design in any depth, so treat it as a direction rather than a recipe.

That gets harder still when the client is already a coordinator. A stream processor like Flink can run its own two-phase commit across Kafka and other systems. Put a weaving router in front of Kafka and Flink sees one participant, while the router has to act as a coordinator for the clusters behind it: two-phase commit nested inside two-phase commit. The KIP describes a flat arrangement of one coordinator and its participants, and says nothing about a participant in the middle.

## What to do today

The router can at least fail loudly. It has to answer `FindCoordinator` before it knows what the transaction will touch, so it picks using something it does know, like the `transactional.id` or the authenticated principal (the [topic routing proof of concept]({% post_url 2026-05-21-topic-routing %}) used the principal). It then rejects a write that strays onto a different cluster. An error in development beats a half-committed transaction in production.

Does it matter? We don't know what your business does with Kafka. Transactions are fine within a cluster, so this is not a blanket ban on using them. The question is whether any single transaction needs to touch topics that live on different clusters. If your router keeps `orders` and `inventory` together, a transaction across them should work as it always did. But transactions may be more pervasive than a first glance suggests. Kafka Streams uses them to provide exactly-once semantics, so an application that never mentions a transaction can still be running one. If that sounds like your estate, check where the topics it reads and writes live before you weave.


## TODO

- [x] Introduction: what the sorting office does that the railway station didn't
- [x] Refresher: how the existing patterns are different (what the client knows, what it doesn't)
- [ ] The topic map: how the router decides which topic lives where
- [ ] The client's view: Metadata, ListTopics, and the virtual namespace
- [ ] Producing: why node ID translation isn't enough, and why PID translation is hard
  - Pull in stash from `stash-replica-routing.md` — "why PIDs aren't node IDs"
- [ ] Consuming: the simpler side — passing upstream PIDs through, `read_committed` caveats
- [x] Transactions: the coordinator lives on one cluster, and that's all
  - Reference Post 3's transactions section; explain how weaving makes it worse
- [x] KIP-939 and why it isn't magic
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
