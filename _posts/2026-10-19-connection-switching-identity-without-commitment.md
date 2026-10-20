---
layout: post
title: "Connection Switching: Identity without commitment"
date: 2026-10-19 15:00:00 +1200
author: "Sam Barker"
author_url: "https://github.com/sambarker"
# noinspection YAMLSchemaValidation
categories: blog kroxylicious-proxy
tags: [ "routing" ]
---

[Post 1]({% post_url 2026-10-12-these-are-not-the-brokers-you-are-connecting-to %}) introduced the Routing API and the fundamental shift it brings: a Virtual Kafka Cluster (VKC) is no longer a fixed pipe wired to a single physical cluster on boot. It's a stable identity. What actually lives behind it is now the proxy's problem, not the client's.

We called the first pattern **Connection Switching**.

Connection switching makes the smallest possible change to Kafka protocol semantics. A connection to a VKC is still a connection to exactly one physical cluster — no fan-out, no merging, no weaving. The broker on the other end behaves like any Kafka broker, because it is one. What the proxy adds is a single degree of freedom: *which* cluster. Think of it in DNS terms: we transform a hardwired A record into a CNAME. The client has a stable name; where the traffic actually lands is entirely up to the proxy.

Post 1 framed it as throwing the lever before the train departs: the routing decision is made once at connection time, and after that it's a straight run to the destination. That's still the right picture. This post is about what you, as stationmaster, have to do so that the trains switch tracks cleanly — and why some passengers will notice the scenery changed.

## What you can do with it (and the dream it sets up)

### The single front door: Tenant & workload dispatch

Workload contention is one of Kafka's classic growing pains. It starts quietly: a few teams sharing a cluster, everything fine. Then the analytics team kicks off their end-of-month backfill and the latency-sensitive payment service starts missing SLOs. The broker's I/O is not infinite, and the batch job's freight train doesn't yield to the passenger express.

The obvious fix — separate clusters for separate workload tiers — runs straight into the coordination problem. Spinning up dedicated hardware is the easy part. Migrating the workloads means issuing new bootstrap addresses, which means finding every application team, convincing them this is their problem too, waiting for their next deployment window, and hoping nobody hardcoded the old address somewhere. Do it for twenty teams and you've bought yourself a multi-week project, a spreadsheet of who's done and who isn't, and at least one Friday evening incident when the team who said they were done turned out not to be.

With connection switching, you skip all of that. Everyone bootstraps at `kafka.corp.internal:9092`. When a client connects, the router inspects the authentication context — who is knocking on the door? — and dispatches to the right cluster behind the scenes:

- High-throughput production services get routed to dedicated, high-IOPS NVMe brokers.
- Heavy batch analytics jobs get dispatched to the spinning rust cluster.
- General application traffic stays on the shared tier.

To be clear: this only affects trains being dispatched going forward. Any freight already at the old yard still needs to be cleared — by hook or by crook. Consume it directly from the old backing cluster, replicate it across with MirrorMaker, or accept that some historical data lives in a different place for a while. Connection switching solves the coordination nightmare going forward. The historical tail is still yours to manage.

### Kafka doesn't do CNAMEs

Swapping a CNAME is how the rest of the world handles this. Update the record, wait for the TTL to expire, done — clients follow along without noticing.[^1]

Kafka can't do that. Kafka connections are persistent and long-lived. Flipping a DNS record does nothing to existing TCP connections; clients will happily keep talking to the old brokers until something drops their socket. Even after the DNS TTL expires and the new record propagates, existing clients don't disconnect. Instead, they only trickle over to the new cluster as individual applications happen to restart, redeploy, or hit network blips over the following hours or days.

Swapping a CNAME gives you the illusion of a clean cutover, but in the words of Admiral Ackbar: *"It's a trap."* You haven't executed a cutover; you've stumbled into an unplanned active-active deployment. Some portion of your producers and consumers are still writing to Cluster A while the rest commit to Cluster B, leaving your data consistency and offset state caught in the middle.

Connection switching gives you the clean cutover DNS promises, but with the coordination Kafka actually needs. The bootstrap and broker endpoints remain stable. When you flip the route target, the proxy severs existing downstream connections in a single, coordinated cut. Every client hits its built-in reconnect loop at the same time, re-establishes connections to the stable proxy endpoints, receives the metadata map for the new cluster, and carries on—moving all traffic from Cluster A to Cluster B without spending hours trapped in an unintended active-active limbo.

Let's be realistic: getting clients to point at a new cluster isn't the hardest part of a migration or DR scenario. Data consistency is what keeps Kafka operators awake at night — topic replication, offset mapping, replication lag, and consumer state. Connection switching doesn't solve any of that (that's still on you and your replication tooling). But what it *does* do is take client endpoint coordination off the critical path. You don't have to chase twenty application teams into a midnight maintenance window just to change their configs.

When executing a planned migration or a DR failover:

- **The data plane is handled out-of-band:** Topics and offsets are synced beforehand via active replication (MirrorMaker 2, [KIP-1279](https://cwiki.apache.org/confluence/display/KAFKA/KIP-1279%3A+Cluster+Mirroring) cluster mirroring, or your vendor's equivalent), or recovered from storage volume snapshots.
- **The connection cutover is a control-plane flip:** The proxy updates its route target to the secondary cluster and closes existing downstream connections. Clients reconnect to the stable bootstrap address, issue a fresh `MetadataRequest` against the new target, and resume. The Kafka client's standard reconnect loop is the recovery mechanism; no application-level coordination is required.
- **Rollback is fast:** If the secondary cluster misbehaves under live load, you can revert the routing target in seconds — with a few bonus state management headaches.

Whether you're doing a planned blue/green transition or invoking DR in an emergency, connection switching means the cutover itself doesn't involve herding cats.

## How the proxy makes it work

[Post 1]({% post_url 2026-10-12-these-are-not-the-brokers-you-are-connecting-to %}) established that Kafka clients care intensely about broker identity: *Broker 1 is Broker 1*. When a client bootstraps, it asks for a cluster map and manages direct connections to each broker at the address advertised for its `NodeId`.

If you've ever used a modern public transit map or navigated an airport terminal, you know that nobody navigates by real geography. Harry Beck's famous 1931 London Underground map—the inspiration for virtually every subway schematic and transit diagram that followed—worked because travelers don't care about winding tunnels or true physical distances. They only care about topology: which station connects to which, and where you change trains.

Kafka clients operate on the exact same premise. They have no concept of physical infrastructure; their entire mental model of the world is the schematic map handed to them in a `MetadataResponse`. As long as that map is internally consistent, they're happy.

To swap the physical reality behind that schematic without breaking client expectations, the proxy runtime has to solve two concrete problems:

1. **Drafting the map on the fly:** The proxy needs to know which upstream brokers exist. Rather than surveying the network ourselves and hardcoding it into configuration — I work hard at being lazy — we just look at the map the client is already requesting and learn it in-band.
2. **The Platform 2 problem:** Tell someone to board "the train on Platform 2" at King's Cross without qualification, and one person is on the mainline concourse waiting for the Edinburgh express while the other is three escalators down on the Piccadilly Line. If Cluster A and Cluster B both contain a "broker 2" (and they almost certainly will), we must deterministically translate node IDs so the client never boards the wrong train.

Here's what's actually happening under the hood.

### Topology discovery happens in-band

What's the point of being a Layer 7 protocol proxy if you don't take advantage of the protocol? Kafka already advertises the broker layout as part of every `MetadataResponse`—so the proxy simply listens in.

Doing discovery in-band means we don't need background polling loops, synthetic health checks, or separate privileged admin credentials to keep an out-of-band cluster map warm. When a route's topology is unknown, discovery inherits the client's authenticated connection, and the proxy harvests the broker layout from the traffic that flows through.

Topology state is cached per-router and shared across all connections using that router — so a second connection to the same virtual cluster benefits from what the first one already discovered. The cache is append-only: entries are added as they're learned, never removed. That matters for safety more than it might seem. A low-privilege connection might get a filtered `MetadataResponse` covering only the topics it can see; an append-only cache means it can only *contribute* knowledge, never silently evict entries that a higher-privilege connection established. And before the security researchers start slinging CVEs — the cache isn't allowed anywhere near an authorisation decision. Brokers enforce ACLs on every request regardless; a misdirected frame gets an error, not someone else's data.

When a client connects with a request and the proxy doesn't yet know the topology — on first connection — it discovers it on demand. This is why you don't need to specify all the upstream brokers in config. The proxy synthesises a `MetadataRequest` and sends it upstream over the client's authenticated connection, uses the response to populate its topology cache, and then forwards whatever the client sent as normal.

This is all proven technology from the pre-routing world, but routing throws us a curve ball.

### When is 2 != 2?

When broker 2 on cluster A and broker 2 on cluster B are both hidden behind the same router. Welcome to the Platform 2 problem: telling someone to board "the train on Platform 2" is ambiguous when both the mainline railway and the deep Underground line share the same front doors. Without translation, two completely different destinations collide under the same number.

A single connection only ever references a single cluster at a time. However many clusters are behind the proxy, the IDs in the `MetadataResponse` must paint a single coherent picture. We can't give the client an identity crisis by presenting N different addresses for node 2. The ID space the client sees must be stable: if NodeId 4 meant cluster A's broker 2 before the cutover, it can't silently start meaning cluster B's broker 2 after it.

The proxy has always rewritten broker addresses in `MetadataResponse` frames — that's how clients end up talking to the proxy rather than the real brokers. Routing adds a wrinkle: we're no longer dealing with a single upstream ID space. There's one downstream space facing the client, and a separate upstream space per physical cluster behind the proxy.

In the pre-routing world that was a trivial identity mapping (not that we identified it as such): Broker 2 upstream was Broker 2 downstream; only the advertised socket address changed.

Routing breaks that simplicity by introducing **multiple upstream ID pools**. That would be trivial if those pools were provably disjoint — if Cluster A only ever used IDs `0..99` and Cluster B used `100..199`. But in the real world, almost every Kafka cluster starts numbering its brokers from 0 or 1.

To keep the runtime's shared topology cache unambiguous and to prevent collisions across a cutover, we have to collapse multiple upstream ID pools into a single downstream space:

```
                                                    ◄──(cluster A IDs)──► [ broker1.cluster-a, broker2.cluster-a, ... ]
[ Client ] ◄──(downstream IDs)──► [ Router ]
                                                    ◄──(cluster B IDs)──► [ broker1.cluster-b, broker2.cluster-b, ... ]
```

The proxy solves this with a stateless and deterministic mapping function applied at each step in the routing DAG — technically speaking, a bijection. No database lookup, no distributed coordinator — just integer arithmetic:

`downstreamId = (upstreamId * numRoutes) + routeIndex`

If Cluster A is route index 0 and Cluster B is route index 1 across two routes:
- Broker 2 on Cluster A becomes virtual Node ID `(2 * 2) + 0` = **4**
- Broker 2 on Cluster B becomes virtual Node ID `(2 * 2) + 1` = **5**

Requests flowing upstream have their node IDs translated from downstream to upstream; responses flowing downstream have them translated back. The mapping is strictly one-to-one in both directions, so every downstream ID resolves to exactly one physical broker and route with zero ambiguity.

Two things follow from this that are specific to connection switching and worth saying plainly.

**Routers must present coherent clusters.** For a router to be a "connection switch" it has to present a single coherent cluster as if the client was connected directly to the backing cluster. Even if it is maintaining an active connection to the hot spare for liveness purposes, it has to ensure the cluster the client sees only contains nodes from the active one. If the backing cluster has 3 nodes, so must the client-facing one. The runtime ensures a complete ID space across all configured routes. What the router puts in the `MetadataResponse` is its business — for connection switching, that's one cluster, full stop. As a rule of thumb: if you find yourself wanting to merge `MetadataResponse`s, you're not doing connection switching any more.

**The ID space is virtual.** That's not a bug, it's intentional — and worth knowing. A client is talking to nodes mapped in the downstream address space. This means that a client thinks it's talking to node 4, but the proxy is translating that to node 2 once it's been through the router. In normal operation you'll never notice. It only becomes salient when you are trying to map logs between clients and brokers, because each end of the exchange has a different view of identity.

Unlike most of the routing API — which gives you the mechanism and expects you to supply the logic — this is one the runtime just handles. The mapping just happens at every route boundary whether your router thought about it or not. Routers work entirely in virtual ID space; the mapping isn't even exposed to them.

Because the mapping is purely local to each router, routers compose cleanly without coordinating with each other. A router doesn't need to know what the rest of the graph looks like or whether an upstream target is a physical cluster or another router in the DAG. The runtime handles the integer translation transparently on the wire, leaving custom routers to work with clean `VirtualNode` handles and focus solely on routing decisions.

There is one constraint baked into the formula: `numRoutes` must be stable for the mapping to be stable. Add or remove routes and the multiplier changes, which reassigns every virtual NodeId — so that's a coordinated reconnect event for all clients on that VKC. In practice that's fine: route topology changes on a different timescale to targets. A new tenant is added or leaves at the glacial pace of humans making decisions; targets flip in an incident at 2am. Stable for what changes slowly, flexible for what changes fast.

## Proxies aren't magic

Layer 7 protocol inspection gives you a lot of leverage. What it doesn't give you is the ability to reach inside a Kafka broker and move its internal state somewhere else. The proxy can route frames to a different cluster. It cannot conjure the state those frames depend on. The points switch cleanly, but the tickets still say the 3:15 to Mos Eisley, carriage 13, seat 342323 (in Kafka terms, `topic-A.partition-13` at offset 342323). The new station has never run that service, and has no record of anyone booking a seat on it. That's how the passengers find out the scenery changed.

### When you flip the target, the state doesn't follow

If the routing target changes while a client is active:

- **Transactional producers:** Transactions are scoped to a single cluster, because the Transaction Coordinator is a role inside it. There's no extension point for an external one, so there's nothing for the proxy to stitch a transaction across two clusters with, however closely they resemble each other. The second cluster's coordinator knows nothing about a transaction the first one opened. If a cutover lands mid-transaction, the subsequent `EndTxnRequest` arrives at the new target and gets back `INVALID_TXN_STATE` or `UNKNOWN_PRODUCER_ID`. The producer has to abort and restart its transactional loop — the same recovery it needs after a fenced epoch or an expired transaction, which well-written transactional producers already handle.

    A proxy restart on its own is harmless. PIDs and transaction state are scoped to the cluster, not to a broker, so as long as the producer lands back on the same cluster, the KIP-360 fencing fields it sends on reconnect are the broker's own real values. Change the cluster and that stops being true: the PID the client holds is meaningless to the new one. Not fenced, simply unknown. The producer reconnects as a stranger.

- **Consumer groups:** Offset state lives in `__consumer_offsets` on the physical cluster. The secondary cluster's Group Coordinator has no idea what the primary's consumers have committed. Fail over without a replication pipeline that carries offsets and consumers either re-read data they've already processed, or skip ahead and lose it, depending on `auto.offset.reset`. Either way, nothing throws an exception to let you know.

- **Idempotent producers:** Deduplication is the partition's memory of who sent what. The leader remembers the recent sequence numbers it has accepted from each producer (PID and epoch), which is how it spots a retried batch and quietly bins it. That memory belongs to the cluster that handed out the PID, so when the route changes it stays behind. The new cluster has never heard of the client's PID. At best the producer is told to start over; at worst a batch that was in flight across the cutover (already committed on the old cluster) is accepted a second time, because nothing on the new cluster can tell it's a retry. The proxy has no way to inject that state.

  Idempotence holds within each cluster, but not across the switch: a cutover is a boundary the guarantee doesn't cross. If you depend on it, treat the cutover as a known risk and either quiesce producers first or make sure downstream consumers can tolerate the odd duplicate. If that isn't good enough, extreme measures exist: a filter could track what it has forwarded and reject re-submitted batches itself. That behaviour is specific to your deployment and would need a custom filter. You know your business better than we do, but it's not one we'd expect to ship as a project.

### Cutovers are an explicit decision, not a proxy heuristic

Every cutover has the consequences above, and the proxy can't repair any of them. That's why automated failover *inside the proxy* is a deliberate non-goal.

A brief network hiccup and a genuine primary failure look identical from inside the proxy. Getting that call wrong — dropping in-flight transactions, replaying messages, committing offsets against the wrong cluster — is a cost the proxy has no way to absorb or undo. That judgement belongs to a human operator, or an orchestration playbook that can actually assess cluster health and replication lag.

Kroxylicious gives you the lever, and it can be thrown without restarting anything. Whether to throw it is the stationmaster's call, and the stationmaster is you, ideally armed with something better than a hunch and a pager.

### Offset continuity requires out-of-band replication

The proxy routes frames; it doesn't replicate log data. If consumers need to pick up where they left off on the secondary cluster, their committed offsets have to mean something there. That means a replication pipeline ([KIP-1279](https://cwiki.apache.org/confluence/display/KAFKA/KIP-1279%3A+Cluster+Mirroring), MirrorMaker 2, or equivalent) that is in place and caught up *before* you throw the lever, not after. If your pipeline translates offsets rather than preserving them, as MirrorMaker 2 does, applying that translation to your consumer groups is part of the cutover too. The proxy won't do it for you. Throwing the lever is not a substitute for having done that work.

### Layer 7 can only do so much

Every failure mode above shares the same root: the proxy routed a frame to a new cluster, and something on that cluster had no memory of the client. That isn't a proxy bug. It's the definition of where connection switching ends. Post 1 framed the four patterns around a single axis: how deep into the Kafka protocol the router has to reach. Connection switching is the shallow end — it makes one decision, which way to throw the points, and then steps back. The journey that follows belongs to the broker.

The patterns deeper on that axis take on more of that journey. Partition weaving, for example, intercepts `OffsetCommit` and `OffsetFetch` and rewrites partition numbers so that a consumer group can span clusters. That's a different contract: not a harder version of connection switching, but a different pattern, because the axis moved. Some limits move with it. Others, like transactions, don't, because they belong to the protocol rather than the proxy.

## Egress, ingress, or does it matter?

Post 1 promised we'd call out where each pattern lands on the egress/ingress axis. From a protocol standpoint connection switching is neutral — the mechanics work either side of the wire. In practice, your use case has a strong opinion about placement.

When talking about DR failover it's obvious once you say it out loud. If the proxy lives in the broker domain — in front of the brokers, a reverse proxy — and the primary site goes down, so does the proxy. Your switch just went boom along with the primary site... a great disturbance in the Force, as if millions of consumers suddenly cried out in terror and were silenced. The secondary site's ingress proxy was never in the traffic path to begin with; you can't flip a routing target on a proxy your clients weren't talking to. You'd still need to redirect clients to a different address, which is exactly the coordination problem connection switching was supposed to eliminate.

Thus for DR, the proxy needs to sit on the client side of the link as an egress deployment. The proxy isn't collocated with what failed. It's still in the traffic path. You can flip the routing target, and clients notice nothing beyond a reconnect.

Connection switching also sits quite happily on the ingress side of the fence. If your goal is workload dispatch — giving every team in the organisation a single `kafka.corp.internal:9092` and routing their connections to the right backing tier behind the scenes — the proxy sits in front of the brokers. The platform team controls that domain, and the stable endpoint is theirs to publish. You *could* run workload dispatch egress-side, but now you're managing a fleet of client-side proxies, one per team or workload, and keeping them all pointed at the same routing config. That's a lot of instances to babysit for a problem the platform team already owns.

So what happens when you want to combine both — cross-site DR failover with platform-side workload dispatch? You chain them together with a proxy at each end of the network link: egress on the client side, ingress on the broker side. The client-side egress proxy handles site-level DR, flipping between primary and secondary regions. The ingress proxy inside each region handles workload dispatch. What makes this work cleanly is that each proxy is completely indifferent to what sits behind it: it dials what it's told, speaks Kafka, and has no idea whether the thing on the other end is a broker or another Kroxylicious instance. There's no shared state between them, no coordination protocol, no handshake. That's the pay-off from being a native layer 7 proxy.

Connection switching keeps the operational promise simple: platform teams can change the physical backend without the application teams having to do anything. The state work above is still yours, but it's work you can do on your own schedule instead of everyone else's. That's not a small thing.

The next post moves from one-to-one connection switching to fanning out traffic and assembling secondary streams on the fly: **Stream Branching**.

---
[^1]: There is always some bit of infra that fails to honour the TTL properly or doesn't understand a CNAME or PTR record.
