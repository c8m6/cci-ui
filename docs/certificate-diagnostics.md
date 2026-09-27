# Certificate usage diagnostics

Diagnostics are optional, read-only observations on the certificate detail page.
Only enabled checks appear. When all checks are disabled, the entire diagnostics
section is hidden; disabled checks show no status, even if earlier evidence is stored.
They do not change date status, summary counts, imports, CSR publication, exports,
activation, archiving or Puppet behavior. German and English statuses include text
as well as color. A self-signed certificate receives a neutral not-applicable
revocation result. No private keys or encryption secrets are loaded.

## Revocation

OCSP accepts a signed response only after OpenSSL verifies its signature, responder
authorization (including delegated OCSP signing), exact certificate/issuer ID and
freshness. The issuer is an explicit, isolated verification anchor; a private CA
need not belong to a browser store. CRLs must have the matching issuer, valid
signature and current dates. Only direct fullName HTTP(S) distribution points
without reason masks are supported. Delta, indirect and issuing-distribution-point
CRLs are explicitly unknown. Absence from a partial list never produces green.
CRLs are cached in PostgreSQL per area, issuer fingerprint and URL digest.

## Scheduling and persistence

`bin/indexer` runs a bounded diagnostic phase after the catalogue lock is released,
including after catalogue failures. A separate PostgreSQL lease with an owner token
serializes diagnostic phases; it expires after the pass budget plus ten seconds.
Late workers cannot publish through another owner's lease. Downloads hold no database
transaction or catalogue lock. Individual check failures do not stop other checks.

Jobs are deduplicated by area, SHA-256 fingerprint and check ID. All retained
versions, including archived/inactive versions, are eligible. Oldest due jobs run
first, with active, unarchived material winning ties. Inventory fingerprint changes
and configuration changes schedule work immediately; ordinary catalogue timestamp
updates do not. Checks disabled for an indexer pass become due on re-enabling.
Recreate both processes when changing environment settings. A disable/re-enable
cycle that never reaches an indexer pass cannot be observed by persisted scheduling.

Evidence stores checked time, expiry, profile/data identity, last attempt and error.
A failed attempt preserves the last conclusive evidence and its original expiry;
known revocation remains visibly dated. Expiry is recomputed at render time without
networking. Evidence expires at the earlier of protocol nextUpdate and the configured
maximum age, and scheduling also observes certificate validity transitions. Failure
backoff starts at five minutes, doubles up to 160 minutes, and never exceeds the
check interval. Deleted/replaced material is revalidated before results are published.

## Configuration

All settings are forwarded to web and indexer in each Compose template. All checks
are disabled by default. Invalid booleans or nonpositive numeric settings prevent
startup. All-disabled deployments make no diagnostic requests.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CCI_OCSP_ENABLED` / `CCI_CRL_ENABLED` | `false` | Independent checks |
| `CCI_OCSP_INTERVAL` / `CCI_CRL_INTERVAL` | `21600` | Seconds between checks |
| `CCI_DIAGNOSTICS_BATCH_SIZE` | `20` | Maximum checks per pass |
| `CCI_DIAGNOSTICS_PASS_BUDGET` | `15` | Total phase deadline, seconds |
| `CCI_DIAGNOSTICS_REQUEST_TIMEOUT` | `5` | Total request deadline including DNS and redirects |
| `CCI_DIAGNOSTICS_CONNECT_TIMEOUT` | `3` | Connection deadline, seconds |
| `CCI_DIAGNOSTICS_MAX_BYTES` | `5242880` | Maximum response size |
| `CCI_DIAGNOSTICS_REDIRECTS` | `3` | Maximum redirects |
| `CCI_DIAGNOSTICS_EVIDENCE_MAX_AGE` | `21600` | Conservative maximum evidence age, also without nextUpdate |
| `CCI_DIAGNOSTICS_CLOCK_SKEW` | `300` | Allowed future clock skew, seconds |
| `CCI_DIAGNOSTICS_ALLOWED_NETWORKS` | empty | Comma-separated internal responder IPs/CIDRs |

Requests use only HTTP/HTTPS on ports 80/443, with no credentials or ambient proxy.
Every DNS answer and redirect is validated, and the selected address is pinned for
the TCP connection (TLS still verifies the original hostname). Loopback, link-local,
metadata, unspecified and multicast destinations are always blocked. Private and
reserved ranges require explicit allowlisting. Compressed HTTP responses are
rejected rather than decompressed. There is no AIA issuer downloading. Existing
area-local public certificates and supplied chains provide issuer candidates.
