---
name: Schema Validation and Enforcement
---

## Schema Validation and Enforcement

### Why do we need Schema Validation and Enforcement?

In Apache Kafka, producing applications transfer messages to consuming applications.  In order for messages to be transferred successfully
producers and consumers need to agree on the format of the message being transferred. If there is a mismatch between the format sent
by the producer and the expectations of the consumer, problems will result.  The consuming application could take the wrong business
action or the consuming application may fail to process the message at all, leading to complete failure of the system.  This problem is known as a *poison message*
scenario.

| ![image]({{'/assets/pages/images/schema_validation_problem.png' | absolute_url}}){:width="100%"} |
|:-----------------------------------------------------------------:|
|    *Problem: Poison message leading to consumer crash*     |

If there is only a small number of applications, perhaps all managed by the same team, it is possible for the developers to use
informal agreements about what message format will be used on which topic.  However, as the use of Kafka grows within the organization,
the amount of effort required to keep all the formats in agreement grows.  Mistakes, and system downtime, become inevitable.

#### Schemas to the rescue

To overcome the problem, the Kafka **client** ecosystem supports _schemas_.  Schemas provide a programmatic description
of the message format.

Producers use a schema to advertise the format of the messages they send.  The consumer uses the same schema to help it
decode the incoming message with the certainty that it conforms to the expected format.

The schemas themselves could be packaged as part of the application.  Whilst the approach is functional, it is quite
inflexible as it means all applications need to be redeployed every time a schema changes.  This becomes a challenge
as the number of applications in the system grows.  To counter this challenge organizations often choose to deploy a
*Schema Registry*. 

#### Schema Registry

The role of the  **Schema Registry**  is to maintain a library of schemas that are in-use within an organisation.

Producer applications call the registry to retrieve the schema for the messages they need to send.

Consuming applications use information embedded in the incoming message to be able to retrieve the right schema from
the registry.  This allows the consumer to decode the message.

| ![image]({{'/assets/pages/images/schema_validation_schema_registry.png' | absolute_url}}){:width="100%"} |
|:-----------------------------------------------------------------:|
|    *Kafka applications making use of a Schema Registry*     |

### So, what's the problem?

If schemas are used correctly across the entire producing and consuming application estate, the potential for a
poison message to be introduced into the system is greatly diminished.  However, the issue is that there's significant
responsibility on the producing applications to configure and use schemas correctly.  There's nothing in the system to
stop, say, a misconfigured producing application using the wrong schema or failing to use schemas at all.

In Kafka, **brokers** have no knowledge of format of the messages (to the broker, a message is just opaque bytes) and they
have no knowledge of the schema.  The brokers cannot help us enforce that producing applications use schemas and use them
correctly.

### Kroxylicious Record Validation

The Kroxylicious Record Validation Filter provides a solution to the problem. 

The filter intercepts the produce requests sent from producing applications and subjects them to validation. If
the validation fails, the produce request is rejected and the producing application receives an error response.  The broker
does not receive the rejected records.  In this way, one can organize that a poison message never enters the system,
even if producing applications are misconfigured.

The filter currently supports two modes of operation:

1. Schema validation validates the content of the record against a schema. Use this for topics which have an entry in
   the Schema Registry. Supported schema types include JSON Schema, Apache Avro and Protocol Buffers (Protobuf).
2. SyntacticallyCorrectJson validation ensures the producer is producing messages that contain syntactically valid JSON.
   Use for topics which do not have registered schemas.

The following diagram illustrates the filter being used for _Schema Enforcement_.  The filter retrieves the expected
schemas from the Schema Registry.  Then produce requests are intercepted, and the records subjected to schema 
validation.

| ![image]({{'/assets/pages/images/schema_validation_solution.png' | absolute_url}}){:width="100%"} |
|:-----------------------------------------------------------------:|
|    *Proxy configured for schema enforcement*     |

The following sequence diagram shows how schema validation issues are reported back to the producer.

| ![image]({{'/assets/pages/images/schema_validation_seq_diagram.png' | absolute_url}}){:width="100%"} |
|:-----------------------------------------------------------------:|
|    *Sequence diagram highlighting error handling*     |

The filter accepts configuration that allows you to assign validators on a per-topic basis.   There are also
configuration options that allow you to define whether the filter rejects just the records that don't meet the
requirements of the validator, or whether then whole batch should be returned.
