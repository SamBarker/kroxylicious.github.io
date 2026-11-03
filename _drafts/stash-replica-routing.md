# Stash: replica routing pattern

Removed from `routing-post1.md` — to be picked up in post 2 (cluster aliasing) as an intra-cluster optimisation.

## Why it's not a peer pattern

The other three patterns (cluster aliasing, union clusters, virtual topics) all answer "which cluster/topic does this request go to". Replica routing answers a different question: "given we've already decided which cluster, which broker within it serves this fetch". It's a different level of abstraction, and it only meaningfully applies to `Fetch` requests — produce requires the leader, and most admin operations that are partition-aware could use it but it's not the primary motivation.

## The pattern

- Client is connected to a VKC backed by, say, the DE cluster
- Client sends a `Fetch` for a partition whose leader is broker 1 in `eu-west-1c`
- The proxy is sitting in `eu-west-1a`, where broker 3 holds a valid in-sync replica of that partition
- Rather than forwarding down the existing pipe to broker 1, the proxy routes the request down a separate connection to broker 3
- Broker 1 never sees the request. The client never knows there was a choice.

The key implementation detail: the proxy doesn't rewrite the request and send it to a different address on the same connection. It has a separate backend connection to broker 3 and routes the `Fetch` down that pipe instead. The request itself is unchanged — what changes is which pipe it travels down.

## Why this needs Layer 7

A Layer 4 proxy sees "connection to broker 1" and can only forward or drop. A Layer 7 proxy reads the `Fetch` request, understands which partition is being requested, knows the replica set and where each replica sits, and can choose which backend connection to use. The routing decision happens at the Kafka protocol level, not the TCP level.

## Relationship to Kafka's built-in rack awareness

This is a complement to rack awareness, not a replacement. `client.rack` + follower fetching works — when clients set it, and set it correctly. Replica routing extends the same idea: the proxy knows its own position in the topology and can apply locality policy centrally, covering clients that haven't configured rack awareness without requiring them to change anything.

## Naming considered

- **Topology-aware routing** — too tied to the implementation word "topology", was the original name
- **Locality routing** — too narrow, implies proximity is the only policy
- **Broker aliasing** — implies a static mapping, but the choice is dynamic
- **Replica routing** — landed here: names the thing being chosen between (replicas), leaves the policy open (proximity, lag, load, cost), intra-cluster by definition

## Other policies beyond proximity

- Replica lag — prefer the most caught-up replica
- Load — prefer the least busy broker
- Cost — prefer replicas on cheaper storage tiers

None of these are proximity, which is why the name shouldn't bake in "locality".

## Failure mode

Proxy placement. A client in `us-east-1a` hitting a proxy in `us-east-1b` that then routes to a broker in `us-east-1a` adds a cross-AZ hop instead of eliminating one. The proxy fleet has to be co-located with clients for locality savings to materialise.

---

# Stash: why PIDs aren't node IDs (for the topic weaving post)

Cut from the stream branching post. Branching never translates the client's PID: the main line passes it through and branch PIDs are router-owned, so this argument isn't needed there. It belongs in weaving, where one client identity has to be valid on several clusters at once.

When you first look at PID management through the proxy, it looks like a problem we've already solved. [Post 2](/TODO-post2-url#when-is-2--2) introduced a bijection for node IDs: a deterministic, stateless mapping between downstream and upstream IDs at each router. PID translation looks like the same problem, and the similarities are convincing. Both are integers. Both are cluster-scoped. Both are assigned by the cluster, not chosen by the client. Both are opaque values the client just carries around and hands back. So the proxy can keep a downstream-to-upstream mapping for both, right? That's the obvious answer, and each problem with it looks fixable on its own until you've fixed several and the whole thing still doesn't hold together. The reason is that although node IDs and producer IDs look identical on the wire, they mean completely different things. A node ID is **spatial**: a label, a coordinate. A PID is **temporal**: not just a label but a claim to be a particular live producer. We can fake a node ID with arithmetic because it's only an address. We have to track a producer ID with state because the broker enforces it as an identity, and fences anyone who presents a stale one.

**Node ID translation is transport-scoped.** A `MetadataResponse` tells the client where the brokers are. The proxy can lie as much as it likes here, because the broker never sees the lies, let alone challenges them. The proxy can also forget: if it throws away its mapping and rebuilds it from the next `MetadataResponse`, it tells the same lies again. Nothing notices and nothing breaks.

**PID allocation is negotiation-scoped.** Since Kafka 3.0, producers run in idempotent mode by default. To support that, the producer sends `InitProducerIdRequest` to ask the broker for an identity: a (PID, epoch) pair. The broker tracks that identity and uses it to deduplicate retried batches during that session. It will also evict any connection that presents the same PID with a lower epoch. That's the fencing mechanism, and it stops two connections claiming the same identity at once. If you need the identity to survive across sessions, so that a restarted producer picks up where it left off, that's what `transactional.id` is for. A second `InitProducerIdRequest` with the same `transactional.id` is deliberately treated as a hostile takeover: fencing is how Kafka makes sure only one producer instance is ever active for a given transactional identity.

Node IDs and PIDs are both cluster-scoped: issued by one cluster, honoured within it, meaningless outside it. But the node ID mapping is stateless. If the proxy loses it, the proxy rediscovers and recomputes it. A PID can't be recovered that way. Once the negotiation is lost, so is the identity.

The upshot is that the proxy can't manage PIDs globally, and the Routing API doesn't try to. No built-in abstraction handles this for you. Whoever writes the router has to work out what their routing topology means for producer identity.

## Weaving: what the PID argument means for producing vs consuming

The PID argument bites on the produce side only. The consume side works without any PID state.

**Consuming: pass the upstream PID through.**

- The PID, epoch and base sequence appear once per batch, in the batch header. Records carry only deltas, so nothing per record needs rewriting.
- A `read_committed` consumer sees the same upstream PID (call it U) in three places: data batch headers, control batch (commit/abort marker) headers, and the `aborted_transactions` entries in the fetch response. All three are written by one cluster for one partition, so they are consistent with each other.
- The consumer matches them against each other and never presents a PID back to a broker. There is no need for a U to D (downstream PID) mapping on the fetch path.
- Caveats, all filter-author rules rather than weaving problems:
  - A filter that rebuilds fetch-response batches must preserve PID, epoch and control-batch flags, and keep `aborted_transactions` consistent.
  - Offsets must stay untouched. `first_offset` in the aborted list is a per-partition offset. Partition weaving rewrites partition numbers, not offsets, so it is fine.
  - Admin APIs (`DescribeProducers`, `ListTransactions`) expose U, not D. A minor observability gap.
- Losing PID state does hurt `read_committed` consumers indirectly, via the produce side: a lost mapping leaves transactions hanging until `transaction.timeout.ms`, which holds back the LSO.

**Producing: this is where it gets hard.** (Parked issues to come back to.)

- The PID is inside the CRC-covered part of the v2 record batch. Mapping D to U means decoding every produce batch, rewriting `producerId`, `producerEpoch` and `baseSequence`, and recomputing the CRC32C. Weaving therefore gives up zero-copy entirely.
- If the D to U mapping is lost, the router allocates a fresh U' for the same D. The log then holds the same logical producer under U and U' with nothing linking them. A transaction started under U cannot be completed under U'. It hangs, or the broker aborts the part written under U while the client believes it committed (silent loss, not just a stalled LSO).
- Each cluster allocates PIDs independently, so U on cluster A and U on cluster B can be different producers. Harmless per partition, but it would break any consumer logic that keyed on PID across partitions. No known client does this.

## Weaving: KIP-939 is not magic (link to the Gemini write-up)

TODO: link the Gemini doc from the weaving post: <https://docs.google.com/document/d/1ShcWeGuP1kMAzqFtEmjuIIAMJJre0Uy4bzkWm3bZbZ8/edit?usp=sharing>

Point to make: KIP-939 (two-phase commit support) still does not fix this. If we went anywhere near it we would be in full distributed consensus pain. Not read or verified yet. Summarise from the doc before quoting, and check its claims against the KIP.

## Topic ID is also temporal
1. Topic IDs / UUIDs (KIP-516)At first glance, a Topic ID looks spatial (it’s just a coordinate for a topic). But it is actually a temporal lifecycle marker generated by the KRaft controller.The Semantics: If you delete a topic and recreate it with the same name, it gets a new UUID to prevent zombie delayed fetches from corrupting the new log.Why it breaks stateless math: You can mathematically fake a Node ID using $V = id + S \times t$ because Node IDs are predictable integers. You cannot mathematically derive a random backend UUID from a frontend virtual UUID.The Proxy Seam: To support API versions v13+ (where Produce and Fetch requests use UUIDs instead of strings), the proxy must maintain a stateful [Virtual Topic UUID -> Physical Topic UUID] mapping table in memory. If a proxy replica restarts and loses that map, it cannot route the frame. This is exactly why a proxy might intentionally cap PRODUCE API versions to v12—forcing clients to use string names—just to avoid handling cluster-specific Topic IDs.   
