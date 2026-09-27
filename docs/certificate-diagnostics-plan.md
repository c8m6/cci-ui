# Certificate diagnostics implementation stages

All stages extend the existing indexer and persisted, area-scoped diagnostics.
They never change operational certificate status or load private keys. Disabled
checks are hidden, and the complete section is hidden when no checks are enabled.

1. **Completed:** bounded scheduling, durable evidence, OCSP and CRL verification,
   independent feature switches, localized detail-page display and synthetic screenshots.
2. **Completed:** independent Chrome, Firefox, Edge, Safari/Apple and Ubuntu
   public TLS trust profiles. Verify authoritative source provenance and purpose
   metadata, cache validated datasets atomically, enforce source freshness, and
   evaluate alternate paths with isolated trust anchors. Clearly distinguish
   incomplete issuer evidence from public distrust and CA evaluation from leaf
   TLS-server evaluation. Document exact targets and limits of vendor policy coverage.
3. **Completed:** independently enabled additional Chrome root-store constraints,
   version conditions, DNS subtrees, validity-start boundaries, anchor rules and
   cryptographically verified embedded SCT evidence from signed CT log metadata.
   Unknown rules or missing required evidence must not yield a green Chrome result.

Each stage requires synthetic fixture tests, the full containerized Rails suite
with PostgreSQL and Consul, RuboCop, updated documentation and affected screenshots,
and a separate Conventional Commit. Leave the local development stack healthy.
Do not merge or publish a release as part of this work.

Optional diagnostic HTTP proxy support is complete. `CCI_DIAGNOSTICS_HTTP_PROXY`
routes responder and public source requests while preserving destination checks.
