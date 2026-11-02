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

## Whose map is it anyway?

All of this hangs on one fact: every router owns a map, the `Metadata` response the client ends up seeing. The proxy supplies the plumbing to send a request down a route and get the response back, and that's all it does. It doesn't merge anything. Merging, splitting a request across clusters and stitching the replies back together are the router's job, and so is deciding what the map says.

That's true of every router, not just a weaving one. A connection-switching router owns a map too, because it decides which cluster's answer the client sees. Routers can also be stacked in the DAG, so a router further along may change the map again. Each router is responsible for the changes it makes.

The map is also written for whoever is asking. Nothing says two clients get the same `Metadata` response. The router can give each identity its own view, as long as every proxy instance gives that identity the same answer. If two instances disagree, topics appear and disappear depending on who answered. It also means the router has to know who is asking, so this depends on authentication being in place.

### Where the map comes from

The simplest source is a table you write down: `orders` is visible from cluster A, `payments` from cluster B. That's a static, client-facing map. The config says what *should* be visible from each backing cluster, but it can't invent a topic. If `payments` doesn't exist on B, it doesn't appear, because the router can only show what the cluster actually has. The trouble is that it's static. Clusters drift. Somebody creates a topic the map has never heard of and it stays invisible until a human edits the config. Somebody deletes one and it quietly vanishes from the client's view.

A rule lets the map follow the clusters instead. The simplest is a prefixing router. Say each of the clusters has an `orders` topic. The router gives every cluster a prefix and applies it to whatever that cluster reports, so the client sees `london_orders`, `tokyo_orders` and `newyork_orders`. Nobody has to tell it about a new topic, because it never had a list. The rule has to be deterministic, though: `orders` from the "London" cluster must be `london_orders` today, tomorrow, after every restart, and on every proxy instance.

The rule has to run in both directions. The prefix goes on in `Metadata` responses. It comes off again in every request that names a topic, and the router uses it to pick the cluster. The brokers never hear of `london_orders`. It could be argued that the topic name now leaks the physical reality, since it says which cluster the topic lives on. That may be intentional and is perfectly reasonable when it is. From the client's point of view it's a naming convention, not a routing decision.

A catalogue service is the same idea with the rule replaced by a lookup. It says which physical topic on which cluster is known to an identity as what, so the names don't have to follow a pattern at all, and it can change at runtime. Either way the router translates in both directions.

### Who sees what

Whatever the source, the router still decides what ends up in the response. When two clusters both have an `orders`, it can include only cluster A's, include both with a prefix, or exclude both. That is policy, and it belongs to the router.

Because the map is per identity, the same machinery covers RBAC, tenant-specific rules and filtering. A topic can be visible to one identity and absent for another. What no map can do is move a topic. It only says where one is.

### Writing to the map

Everything so far has been about reading the map, and reading is aggregation. Each cluster reports what it has and the router combines the answers into one view. The clusters are the source of truth, and the router only decides which of their answers to show. Writes run the other way, and there is no source of truth to consult. A client calls `CreateTopics` for `X`: one request, which the router has to turn into work for some of the clusters. One, several or none. Neither the request nor the clusters say which. That's disaggregation, and the answer can only come from policy. There's no automatically correct one, and each option has a price:

- **A default cluster.** Simple and predictable. But one cluster risks becoming a hotchpotch of disjointed topics, and nothing about where the data ought to live gets a say.
- **A rule on the name.** `london_orders` goes to London. No state, and the map follows for free. But the name is the placement, so moving a topic means renaming it, and a name that doesn't fit the convention needs somewhere to go.
- **A catalogue.** Placement is decided centrally and names can be anything. But a create is now two steps, update the catalogue and create the topic, and either can fail and leave the other behind.
- **Every cluster.** The name exists everywhere, which is convenient for reads. It doesn't share any data, since each cluster still holds its own. But the create is now a dual write, the problem from [stream branching]({% post_url 2026-10-26-stream-branching-mind-the-gap %}). If it works on A and fails on B, the topic half exists, and the router has to decide what to tell the client.
- **Refuse.** The platform team owns the topology and nothing surprising appears. But anything that creates topics for itself, Kafka Streams being the usual suspect, stops working.

All of these are legitimate. Which is right depends on who owns the topics and how much you trust the clients, so it's the router's call and the proxy has no opinion.

The one rule is that a write has to agree with the map. If the create lands on cluster B but the map says `X` lives on A, or doesn't mention `X` at all, the client is told it worked and then can't find its topic. A prefix rule gets this for free, because the prefix already says where `X` goes. A table or a catalogue has to be updated as part of the create, and that's the router's job too.

`DeleteTopics`, `CreatePartitions` and `AlterConfigs` are the same question with a different verb: how many clusters, and which. Once the topic exists the map answers it.

## Broker IDs collide too

Topic names aren't the only thing two clusters can have in common. Nearly every Kafka cluster numbers its brokers from 0 or 1, so cluster A has a broker 2 and so does cluster B. It's the Platform 2 problem from [post 2]({% post_url 2026-10-19-connection-switching-identity-without-commitment %}) again, and it's no less fatal here: put both in one `MetadataResponse` and the client has two different brokers answering to the same number. Broker 2 is Broker 2, remember.

The good news is that nobody writing a router has to deal with it. The runtime does, at every route boundary, with the same bijection as before: `downstreamId = (upstreamId * numRoutes) + routeIndex`. Broker 2 on route 0 becomes 4, broker 2 on route 1 becomes 5, and requests are mapped back again on their way upstream. A router never sees the formula, only the IDs on its side of the boundary.

That last part is what allows us to compose routers into a DAG, and thus manage the complexity. What a router calls node 4 might be a real broker, or it might be a virtual node presented by another router further along. It neither knows nor cares. The IDs the client uses are the downstream side of the first router it meets; everything upstream of that is somebody else's business, with its own mapping at its own boundary. They compose without anyone having to coordinate.

For weaving, that makes merging a non-event. Each route's `Metadata` arrives already mapped into the router's ID space, so the broker lists can be concatenated without a thought for collisions. It's a bigger deal than it was for connection switching, where the client only ever saw one cluster's brokers at a time. Here every cluster's brokers are live at once. The constraint from post 2 comes along too: change the number of routes and every ID moves.

Node IDs are the easy case. They're a pure function of where a broker lives, so the runtime can translate them with arithmetic and no memory. Not everything the client carries around is that obliging.

## Producer IDs are not node IDs

A producer ID looks like the same problem. It's an integer, a cluster hands it out, and the client carries it around and hands it back. So why not map it the same way? Because a node ID is spatial and a producer ID is temporal. A node ID is a coordinate: the proxy can lie about it as much as it likes, because no broker ever sees the lie, and if the proxy forgets its mapping it rebuilds the same one from the next `Metadata` response. A producer ID is a claim to be a particular live producer. The broker tracks it, uses it to discard retried batches, and fences anyone who presents it with a stale epoch. Lose the mapping and you can't recompute it, because the identity was negotiated rather than derived.

That matters because every idempotent producer has one, and idempotence is the default. Each cluster issues its own `(producer ID, epoch)` pair, and the pair from cluster A means nothing to cluster B. The router has to give the client one identity and keep a map to the rest.

It also costs more than node IDs did. The producer ID is inside the checksummed part of a record batch, so rewriting it means decoding the batch, changing the header and recomputing the CRC. Weaving gives up zero-copy on the produce path.

### Where the map lives

The map has to survive a proxy restart and be visible to every proxy instance, because a client holds one connection per partition leader and those can land on different instances. So it needs a store, and building a consensus layer into the proxy is the wrong answer.

Kafka already has durable, replicated storage, so use it. Pick one cluster to be the **boss**. On it, keep a compacted topic keyed by the client's producer ID, whose value maps each backing cluster to the `(producer ID, epoch)` it issued. When the client calls `InitProducerId`, the router initialises a producer on every backing cluster, writes the map to the boss, waits for the ack, and only then replies. Any instance that sees an unfamiliar producer ID reads the topic to find the map, and caches it from then on.

The map is small and changes only at init or when an epoch is bumped, so none of this is on the produce path. The sequence numbers are the part you'd expect to be hard, and they turn out not to be. They're counted per producer and partition, a partition lives on exactly one cluster, and weaving sends each client batch upstream as exactly one batch for the same partition. The router passes the sequence through untouched. Only the producer ID and epoch are rewritten. As long as every cluster's producer is initialised together, the counts start in step and stay there, so nothing needs storing per batch.

That doesn't make it free:

- **The boss is a dependency.** If it's down, no new producer can start. Existing producers carry on from each instance's cache, but a restarted instance has to read the topic before it can serve them.
- **Initialising everywhere is eager.** One backing cluster being unavailable blocks new producers on all the others, including ones that would never have written to it.
- **The map needs cleaning up.** Every short-lived producer leaves a key that compaction keeps until something removes it.

We haven't built this, so treat it as a direction rather than a recipe. The boss will come up again.

### Consuming is the easy side

A consumer never hands a producer ID back to a broker. A `read_committed` consumer sees the one cluster's ID in the batch headers, the commit and abort markers and the aborted-transaction list of a fetch response, and all three come from the same cluster for the same partition. They already agree with each other, so the router passes them through. The one rule is for anything that rebuilds fetch batches: preserve the producer ID, epoch and control-batch flags, and keep the aborted list consistent.

## Picking a boss

The producer ID map is the first time we have reached for a **boss** cluster, but the underlying problem keeps recurring.

Reads aggregate naturally. Every cluster reports what it has, and the router combines the answers into a single view. Writes and state do not aggregate, because there is no existing reality across the clusters to consult. When a client creates a topic, negotiates an identity, or coordinates a decision, the router cannot ask the backing clusters for an answer that does not exist yet. It has to make a choice, and it has to remember what it chose. That memory must survive proxy restarts and be shared across a fleet of proxy instances without inventing a new consensus layer. The Kafka-native answer is to pick one cluster to host that shared state: a **boss** cluster.

None of the boss cluster roles are tested. They make sense in principle, but they split on what the cluster is asked to do:

| Problem | Job | In principle? |
| --- | --- | --- |
| Topic creation (`CreateTopics`) | Default cluster for new topics (or catalogue store) | Works, with the hotchpotch caveat |
| Producer ID mapping | Registry in a compacted topic | Works |
| Transactions | The boss's coordinator runs every transaction | Fails (participant) |
| Distributed commit (KIP-939) | Decision log for two-phase commit | Feasible, untested |

The test for whether a boss works is whether it acts as a **store** or as a **participant**.

When the boss is a store, it holds proxy bookkeeping in internal topics. The proxy writes its state there and reads it back; the brokers on the boss are just durable storage for bytes, and the proxy enforces the semantics. When the boss is a participant, client traffic lands on it directly. Any write to the boss cluster makes it a participant. That works for `CreateTopics` where the boss hosts the newly created topic, but it fails when the boss is expected to participate on behalf of other clusters. A transaction coordinator on the boss can track and commit writes to its own partitions, but it rejects writes to partitions on other clusters because they do not exist in its metadata.

Where that boss cluster lives is a separate choice:

- **One of the data clusters.** The cheapest option: no extra infrastructure to deploy or monitor. But you couple the control plane of all your clusters to one of them. If that data cluster goes down or undergoes maintenance, administrative operations and new producers stall across the entire mesh.
- **A small dedicated cluster.** Isolates the router's state and blast radius from tenant data traffic. If a data cluster fails, only its own topics are affected. The cost is the operational overhead of running one more Kafka cluster.

## What a weaving router has to do

Whichever way the map is built, the router has three jobs:

- **Metadata.** Ask every backing cluster, keep the topics the map shows this identity, and return the lot as one response.
- **Produce and fetch.** Group the topics in a request by the cluster they belong to, send the pieces in parallel, and merge the replies into one.
- **Enforce the map.** Apply the same rules to every request that names a topic, not just `Metadata`. Hiding a topic from a response isn't enough if a `Produce` can still name it.

This section describes what a router for this pattern has to do, not a list of features you can switch on today.


## Transactions stop at the cluster boundary

A transactional producer starts by sending `FindCoordinator` for its `transactional.id`, then `InitProducerId` to whichever broker the answer names. From then on that coordinator tracks the transaction, and when the producer commits it writes the commit or abort markers to the partitions involved. The coordinator, its transaction log and those markers all belong to one cluster.

A coordinator can only see its own cluster, so the obvious answer is to give the client one everywhere. The router fans `InitProducerId` out to every backing cluster and starts a transaction on each. As the client registers partitions and produces, the router sends each call to the cluster that owns the topic, using the producer ID and epoch that cluster issued. The client holds one producer ID and the router holds the mapping to the rest. That mapping has to survive a router restart and be visible to every proxy instance, so it needs the kind of store described [above](#where-the-map-lives). That's real work, but it's work you can do.

It falls over at commit. The client sends one `EndTxn` and the router has to turn it into one per cluster. On each cluster, commit is a point of no return: once the coordinator has written its decision, it will commit, whatever else happens. Until then it is free to refuse, and each cluster decides for itself. Cluster 1 can pass the point of no return while cluster 2 says no. None of the ways cluster 2 can say no are transient. The transaction may have timed out, since each cluster runs its own clock from the first partition added there. A zombie may have bumped the producer epoch. The ACLs may differ. Then `orders` has its records and `inventory` doesn't, and whatever the client is told is wrong for one of them.

A state store doesn't rescue this. It can remember that the router meant to commit cluster 2, but it can't make cluster 2 agree. Reordering the commits doesn't help either, because whichever goes first can't be undone.

So stop negotiating and pick a boss again, but this time as a participant rather than a store. The boss's coordinator runs every transaction. The client's `InitProducerId`, `AddPartitionsToTxn` and `EndTxn` all go there, while the records still go to whichever cluster owns the topic. Commit is now a single decision on a single coordinator, so the atomicity problem is gone.

It doesn't survive the first write to another cluster. The client registers each partition with the coordinator before it writes to it, and the boss's coordinator doesn't recognise `inventory`'s partitions, because they aren't in its cluster. It refuses them, and the transaction never gets as far as commit.

Both attempts fail for the same reason. Somewhere there has to be a moment when every cluster has promised to commit before any of them does, and Kafka's transaction protocol has no such step.

## KIP-939 might add the missing step

[KIP-939](https://cwiki.apache.org/confluence/display/KAFKA/KIP-939%3A+Support+Participation+in+2PC) is the obvious objection. It's accepted, it's about two-phase commit, and it has not landed in Kafka yet. It lets Kafka take part in somebody else's two-phase commit: a producer can prepare a transaction, and a prepared transaction isn't aborted by the timeout while it waits for an external coordinator to decide. That is the promise our two attempts were missing.

In principle the router could be that coordinator. It would start a transaction on each backing cluster, wait for all of them to prepare, record the decision, and then tell each one to commit. The client would still believe it was talking to a single coordinator. The hard part is the middle step. Someone has to durably record the decision between "everyone prepared" and "everyone committed", and survive a crash in the gap. A router that does that needs a durable log of its own, recovery after a restart, and a way to stop two proxy instances disagreeing about the outcome. That is the consensus layer from [post 1]({% post_url 2026-10-12-these-are-not-the-brokers-you-are-connecting-to %}), and the Kafka community has just spent years moving from ZooKeeper to KRaft so that nobody has to run a second consensus system alongside Kafka. Asking a proxy to bring its own would be a step backwards.

That said, this is where the boss earns a second job. The decision log could live in a compacted topic on the same cluster that holds the producer ID map, with nothing new to deploy. The recovery logic is still yours to write. We haven't investigated this design in any depth, so treat it as a direction rather than a recipe.

That gets harder still when the client is already a coordinator. A stream processor like Flink can run its own two-phase commit across Kafka and other systems. Put a weaving router in front of Kafka and Flink sees one participant, while the router has to act as a coordinator for the clusters behind it: two-phase commit nested inside two-phase commit. The KIP describes a flat arrangement of one coordinator and its participants, and says nothing about a participant in the middle.

## What to do today

The router can at least fail loudly. It has to answer `FindCoordinator` before it knows what the transaction will touch, so it picks using something it does know, like the `transactional.id` or the authenticated principal (the [topic routing proof of concept]({% post_url 2026-05-21-topic-routing %}) used the principal). It then rejects a write that strays onto a different cluster. An error in development beats a half-committed transaction in production.

Does it matter? We don't know what your business does with Kafka. Transactions are fine within a cluster, so this is not a blanket ban on using them. The question is whether any single transaction needs to touch topics that live on different clusters. If your router keeps `orders` and `inventory` together, a transaction across them should work as it always did. But transactions may be more pervasive than a first glance suggests. Kafka Streams uses them to provide exactly-once semantics, so an application that never mentions a transaction can still be running one. If that sounds like your estate, check where the topics it reads and writes live before you weave.

## Egress, ingress, or does it matter?

The question from the previous posts returns: should the proxy sit on the client side of the link (egress) or in front of the brokers (ingress)?

The trade-off is very similar to the DR story from [connection switching]({% post_url 2026-10-19-connection-switching-identity-without-commitment %}). Co-locating the proxy with an arbitrary data cluster puts them in the same failure domain. If that cluster has an outage, the proxy instances go down with it—cutting off access to healthy topics on all the other clusters too.

Client-side egress avoids that coupling. When an individual backing cluster goes down, the proxy stays alive. It returns partition-level errors for the affected cluster while continuing to serve produce and fetch traffic to every other cluster normally. For most topologies, keeping backing cluster failures isolated makes client side the safer default.

That doesn't make client side categorically better. If you adopt the boss pattern, co-locating the proxy fleet with the boss cluster has a compelling advantage: **latency**.

Every new producer initialisation, transaction prepare, or catalogue lookup involves the boss. Putting the proxy next to the boss turns those round-trips into local network hops rather than cross-link calls. You accept that the proxy shares a failure domain with the boss—but if the boss is down, those control operations were going to stall anyway.

If you don't use a boss, or if isolating data-cluster outages is paramount, client side is the natural home. If you do use a boss and want fast admin and init paths, co-locating with it is well worth considering.

## Know when to get off the train

Every pattern in this series trades protocol simplicity for operational flexibility. Topic weaving sits near the top of that trade, which makes knowing when *not* to use it just as important as knowing how it works.

If your problem is moving a whole workload, use [connection switching]({% post_url 2026-10-19-connection-switching-identity-without-commitment %}). A blue/green cutover, a cluster migration, or insulating a legacy application from infrastructure churn only needs the router to throw points at connection time. It is completely stateless, involves zero metadata fabrication or PID rewriting, and adds no moving parts. If all the mail is going to the same city, you don't need a sorting office.

If your problem is data locality or disaster recovery, use **replication**. MirrorMaker 2, KIP-1279 Cluster Mirroring, or your vendor's replication engine copy the committed log asynchronously after the fact. Topic weaving lets a client in London reach a topic in Tokyo without configuring a second bootstrap address, but the network packets still cross the ocean on every fetch. If you need local read latency or an independent replica that survives a regional outage, replicate the bytes. Weaving provides unified access; replication provides local copies.

If your problem is tapping an auxiliary stream, use [stream branching]({% post_url 2026-10-26-stream-branching-mind-the-gap %}). Forking a produce stream to feed a staging cluster, an audit topic, or a PII-scrubbed shadow works best when the branch is best-effort and can tolerate the odd gap or duplicate.

**Topic weaving** is the right choice when topics have distinct, legitimate homes across multiple clusters—by team, by tenant, or by compliance boundary—and you want clients to interact with them as a single coherent estate. It eliminates multi-client boilerplate in application code and hides physical cluster sprawl behind a clean virtual catalogue.

The boundary is clear: topic weaving works as long as each topic lives entirely on one backing cluster. If your producers need atomic cross-topic transactions across cluster boundaries, no proxy can fix that; those topics must share a physical cluster. And if even a single topic cannot live on one cluster—if you need its partitions split across different physical environments—you have reached the edge of topic weaving.


## TODO

- [x] Introduction: what the sorting office does that the railway station didn't
- [x] Refresher: how the existing patterns are different (what the client knows, what it doesn't)
- [x] The topic map: how the router decides which topic lives where
- [x] Broker ID collision: recap the post 2 formula, why weaving needs it permanently
- [x] The client's view: folded into the map and "What the client knows" sections (ListTopics is just unfiltered Metadata)
- [x] Admin operations that name topics: "Writing to the map" under "Who sees what"
- [x] Producing: why node ID translation isn't enough, and why PID translation is hard
  - Pull in stash from `stash-replica-routing.md` — "why PIDs aren't node IDs"
- [x] Consuming: the simpler side — passing upstream PIDs through, `read_committed` caveats
- [x] Transactions: the coordinator lives on one cluster, and that's all
  - Reference Post 3's transactions section; explain how weaving makes it worse
- [x] KIP-939 and why it isn't magic
  - Link/summarise the Gemini doc before quoting
- [x] Proxy placement: run it in the client's network/trust zone, not co-located with any single cluster, so a cluster failure doesn't take the proxy with it
- [x] When to use weaving vs replication vs connection switching
- [ ] Closing: what's next in the series

---

*Stash and working notes follow below — remove before publishing.*

---

<!-- stash: PID vs node ID argument (from stash-replica-routing.md) -->
<!-- stash: weaving produce/consume PID treatment -->
<!-- stash: KIP-939 note -->
