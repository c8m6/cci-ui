# CSR implementation plan

## Existing architecture

- Rails 8.1 and PostgreSQL provide the catalog, import drafts and audit events.
  Active Record migrations and database constraints define persistent state.
- Area roles are parsed by AreaConfiguration and checked by Identity. OIDC role
  mapping and local demonstration identities share that contract. Navigation is
  server-rendered with localized labels.
- ConsulStore and CciWriter publish public certificates, encrypted private keys
  and version pointers in one CAS transaction. Existing versions are immutable.
- Certificates::Vault implements versioned AES-256-GCM envelopes with a random IV,
  authentication tag and area/object-bound authenticated context. AreaSecrets
  reads external Base64 keys from CCI_AREA_KEYS or the per-area fallback.
- AuditEvent records mutation intent before external writes and the outcome
  afterward. Secret request parameters are filtered and private responses use
  no-store headers. Audit viewing has its own area-specific role.
- Existing integration/service tests use PostgreSQL and Consul in disposable
  Compose services. Every image build runs RuboCop with rubocop-rake.

## Confirmed decisions

- Add the independent area role <area>_csr. Writer alone grants no CSR access.
- Choose the area and CertID when creating a CSR.
- Retain a matching certificate when its issuer is unavailable. Block Consul
  publication until its signature can be verified.
- Reuse area encryption keys and the existing authenticated encryption envelope.
  Use distinct contexts for the CSR private key and revocation password.
- Store CSR state in PostgreSQL. Publish certificate/key material to the existing
  Consul schema only after a certificate has been uploaded and verified.

## Implementation sequence

1. Add request and issued-certificate tables with foreign keys, uniqueness and
   status constraints. Keep replacement certificate history.
2. Add centralized environment defaults, DNS/IP SAN validation, RSA/EC generation,
   PKCS#10 signing and encrypted secret persistence.
3. Add area-scoped service authorization, CSR navigation, forms, two inventories,
   downloads and separately confirmed, audited password disclosure.
4. Validate uploads against public key, CN and SANs. Resolve issuers from the
   upload or the same area's catalog and preserve pending verification state.
5. Persist prepared CAS operations before publishing. Reconcile immutable Consul
   values after timeouts so retries cannot silently allocate duplicate versions.
   Require explicit confirmation for an existing destination.
6. Keep authenticated CSR pages usable when unrelated dependencies or Consul are
   unavailable. Leave existing application dependency checks unchanged.
7. Add service, authorization, failure/retry and browser tests. Document routes,
   statuses, deployment defaults, backups and coordinated key rotation.
8. Run the full CI Rails suite, rebuild development services and verify HTTP.
