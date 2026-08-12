---
layout: post
title:  "kroxylicious-junit5-extension release 0.16.0"
date:   2026-08-12 00:00:00 +0000
author: "Robert Young"
author_url: "https://github.com/robobario"
categories:  releases junit5-extension
---

The Kroxylicious project is very pleased to announce the [0.16.0](https://github.com/kroxylicious/kroxylicious-junit5-extension/releases/tag/v0.16.0) release of our Junit5 Extension.

Highlights of this release:

* Raised the project's Java baseline to 21, up from 17. Make sure your build targets Java 21 before you upgrade.
* Bumped the Kafka dependency to 4.3.1.
* Relaxed `@BrokerConfig` so you can now override the replication factor of internal topics (offsets, transaction state log, share coordinator state). This helps when testing coordinator failover across multi-broker clusters.

### Feedback

Please let us know, through [Slack](https://kroxylicious.slack.com) or [GitHub](https://github.com/kroxylicious/kroxylicious-junit5-extension/issues), if you find the extension interesting or helpful.
