# Certificate usage diagnostics

A separate collector deployment is under consideration. The
[deferred collector plan](collector-plan.md) records the proposed architecture and
open questions. It is not implemented. The behavior below describes the current
direct/proxy-based diagnostics.

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
need not belong to a browser store. Unsupported critical extensions in either
the signed response or its matching SingleResponse produce unknown; unknown
noncritical extensions are ignored. CRLs must have the matching issuer, valid
signature and current dates. Only direct fullName HTTP(S) distribution points
without reason masks are supported. Delta, indirect and issuing-distribution-point
CRLs are explicitly unknown. Absence from a partial list never produces green.
CRLs are cached in PostgreSQL per area, issuer fingerprint and URL digest.

## Scheduling and persistence

`bin/indexer` runs a bounded diagnostic phase after the catalogue lock is released,
including after catalogue failures. A separate PostgreSQL lease with an owner token
serializes diagnostic phases; it expires after the pass budget plus ten seconds.
Late workers cannot publish or change scheduling through another owner's lease.
Lease validity is checked after acquiring the short database row lock. Downloads hold no database
transaction or catalogue lock. Individual check failures do not stop other checks.

Jobs are deduplicated by area, SHA-256 fingerprint and check ID. All retained
versions, including archived/inactive versions, are eligible. Oldest due jobs run
first, with active, unarchived material winning ties. Invalidation preserves the
original due time of already waiting jobs, including after re-enabling. Each
certificate's dependency identity includes all area-local issuer candidates
reachable within the chain-depth limit, including alternate paths. Adding,
replacing or removing a relevant issuer and changing configuration schedules work
immediately; unrelated arrivals and ordinary catalogue timestamp updates do not.
Checks disabled for an indexer pass become due on re-enabling.
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
| `CCI_DIAGNOSTICS_HTTP_PROXY` | empty (direct) | Explicit HTTP proxy URL for HTTP and HTTPS diagnostic/source requests |
| `CCI_DIAGNOSTICS_ALLOWED_NETWORKS` | empty | Comma-separated internal responder IPs/CIDRs |

Requests use only HTTP/HTTPS on ports 80/443, with no destination credentials.
Ambient `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` variables are ignored.
Every DNS answer and redirect is validated, and the selected address is pinned for
the TCP connection (TLS still verifies the original hostname). Loopback, link-local,
metadata, unspecified and multicast destinations are always blocked. Private and
reserved ranges require explicit allowlisting. Compressed HTTP responses are
rejected rather than decompressed. There is no AIA issuer downloading. Existing
area-local public certificates and supplied chains provide issuer candidates.

### Optional outbound proxy

Set `CCI_DIAGNOSTICS_HTTP_PROXY=http://proxy.example.test:3128` on web and indexer
(the Compose templates forward the same value). An empty value retains direct
connections. This setting covers OCSP, CRL and all public trust-source downloads;
it does not configure Consul, PuppetDB or Keycloak. HTTPS destinations use CONNECT
and retain normal certificate/hostname verification and SNI. The proxy itself uses
HTTP; HTTPS proxy endpoints and automatic bypass rules are not supported.

Optional Basic proxy authentication uses `http://user:password@proxy.example.test:3128`;
percent-encode reserved characters in credentials. Keep real credentials out of
tracked files. Errors and logs contain sanitized reason codes, never the URL or
credentials. Basic proxy credentials travel over the connection to the HTTP proxy.

DNS resolution stays local. Every destination and redirect is checked against the
existing address policy before contacting the proxy. Both HTTP absolute request
URIs and HTTPS CONNECT use the selected validated IP, so the proxy does not resolve
the destination hostname again. HTTP retains the original Host header. The proxy
must support IP destinations with an original hostname Host header; this includes
proxies that use CONNECT for HTTPS. The configured proxy endpoint itself may be on
an internal network. It does not extend the responder allowlist, and vendor source
downloads still require public destinations. Size, redirect and time limits apply.

## Public default CA trust profiles

Chrome, Firefox, Edge, Safari/Apple and Ubuntu are independent optional checks.
Browser results are grouped separately from Ubuntu and revocation results. A green
result means an isolated public CA path passed TLS-server-purpose validation (or
explicit CA anchor/path validation for a CA certificate). This does not test a
hostname, live server, revocation, or the vendor's entire verifier. No host,
container, company, Consul transport or locally inventoried CA becomes a trust
anchor. Area-local public material supplies untrusted intermediate candidates.
Alternate and cross-signed paths are considered, with bounded depth and search.
A chain ending in a private self-signed root is untrusted; missing intermediate
material is unknown. Signature, time, key usage, CA and path constraints are checked.
Successful evidence expires no later than the selected path's next certificate
validity transition or the anchor's scheduled `disabled_at` time. It becomes stale
at that exact boundary even without another indexer pass, which is also scheduled
for the boundary. Re-evaluation can select an alternative still-trusted path.
Issuance cutoffs (`distrust_after`) compare the leaf's fixed notBefore date; they
are not wall-clock expiry dates for certificates issued before the cutoff.

### Source targets and policy coverage

| Check / variable stem | Default target | Authoritative data and interpretation |
| --- | --- | --- |
| `trust_chrome` / `CCI_TRUST_CHROME` | `154.0.8037.57` | Matching Chromium release tag: `root_store.certs`, `additional.certs`, `root_store.textproto`, `root_store.proto` and `LICENSE`. Only TLS anchors are selected. This is that release's baseline, not Chromium `main` or a claim about the roots deployed on every current client. |
| `trust_firefox` / `CCI_TRUST_FIREFOX` | `156.0.1` | Firefox release's NSS `TAG-INFO` and `certdata.txt`; this target contains `NSS_3_128_RTM`. Select server-auth trusted delegators by certificate hash, including `CKA_NSS_SERVER_DISTRUST_AFTER` cutoffs. Other Firefox-specific policies are outside baseline scope. |
| `trust_edge` / `CCI_TRUST_EDGE` | `windows-macos` | Microsoft's public TLS-server-authentication CCADB report, for the Microsoft root-program architecture of Edge 112+ on Windows/macOS. Check PEM fingerprints, inclusion, server-auth exclusions, issuance cutoffs and disable dates. A nonempty TLD restriction that cannot be interpreted yields unknown. The report snapshot digest identifies the dataset; it is not a claim about the exact component installed on a user's device. |
| `trust_apple` / `CCI_TRUST_APPLE` | `macos-15-2024051500` | Apple's macOS 15 source revision `9c061d71693f4b9ccdddea087ff0428755604bf0`, Root Store `2024051500`, combined with Apple's current TLS-purpose CCADB report. Only roots from that OS release are candidates. Missing purpose metadata or unrecognized reported restrictions yield unknown. This conservative intersection does not reproduce every Apple platform policy or later asset update. |
| `trust_ubuntu` / `CCI_TRUST_UBUNTU` | `noble-updates` | Ubuntu 24.04 LTS `noble-updates/main` official `ca-certificates` package (verified during implementation: `20260601~24.04.1`). Verify InRelease's signature against archive signer `F6ECB3762474EDA9D21B7022871920D1991BC93C`, signed package-index SHA-256 and package SHA-256. Read the default Mozilla certificate selection without installing the package or using Debian roots. Actual package version is recorded with each update. |

Chrome and Firefox targets accept numeric release versions; unavailable tags produce
unknown. Apple, Edge and Ubuntu accept only the explicitly supported target above.
Ubuntu repository metadata must be current (at most seven days old), not future-dated,
and within `Valid-Until` when provided. Package decompression is bounded and package
paths are read in memory, never extracted into the application filesystem.

For each stem above, configure `_ENABLED` (default `false`), `_INTERVAL` (86400
seconds), `_TARGET` (table), `_UPDATE_INTERVAL` (86400 seconds), and `_MAX_AGE`
(604800 seconds). Every profile has its own update schedule. Source network settings
are `CCI_TRUST_REQUEST_TIMEOUT=10`, `CCI_TRUST_MAX_BYTES=20971520`, and
`CCI_TRUST_EXPANDED_MAX_BYTES=67108864`. Existing connection, redirect and per-pass
budgets still apply. All settings are validated and forwarded to web and indexer.

One due source is refreshed per indexer phase, before bounded certificate work.
Raw artifacts and validated profiles share the durable PostgreSQL diagnostic cache.
Multi-file acquisition can resume after a deadline; replacement of a validated
profile is atomic and fenced by the indexer lease. Failed updates retain the last
valid profile, original expiry and last error, with bounded backoff. Profile content
changes make certificate checks due. Old results are displayed as stale until
re-evaluated against the new version. Source/profile details include the exact
release, source, verification time, snapshot digest and successful chain fingerprints.
The current maximum source age applies when loading existing profile and
raw-artifact caches. Stored results are also marked stale at that limit as soon
as they are rendered, without network requests.
Age is measured from the original fetch/verification time, or the earlier signed
publication time for CT metadata. Reusing or reparsing cached bytes and failed
refreshes never advance that time. Shortening the age or source-update interval
schedules a source refresh; a failed refresh keeps the prior dataset for history
but cannot make evidence exceeding the new age limit usable again.

### Provenance and licenses

No public root bundle or third-party implementation is copied into the repository.
Original downloaded artifacts (including source notices) are retained in the cache.
The project remains `AGPL-3.0-only`. Runtime source references:

- [Chrome source and schema](https://chromium.googlesource.com/chromium/src/+/refs/tags/154.0.8037.57/net/cert/root_store.proto): Chromium BSD-style notice; source license is cached with the profile.
- [NSS release](https://firefox-source-docs.mozilla.org/security/nss/releases/nss_3_128.html): MPL-2.0 notice remains in the original certdata artifact.
- [Microsoft source authority](https://learn.microsoft.com/en-us/security/trusted-root/participants-list) and [Edge architecture](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-security-cert-verification).
- [Apple macOS 15 store](https://support.apple.com/en-us/121672) and [Apple certificate source](https://github.com/apple-oss-distributions/security_certificates/tree/9c061d71693f4b9ccdddea087ff0428755604bf0). Apple source code is not incorporated; certificate artifacts retain their provenance. The archive does not provide a blanket certificate redistribution license, so these files are not bundled or republished by CCI-UI.
- [CCADB reports](https://www.ccadb.org/resources), attributed to the Common CA Database under [CDLA-Permissive-2.0](https://www.ccadb.org/rootstores/usage). Reports and their license reference are retained with the source data.
- [Ubuntu package](https://packages.ubuntu.com/noble-updates/ca-certificates): package copyright notice is retained. New external command-line dependencies are GnuPG (`gpg`/`gpgv`, GPL-3.0-or-later), XZ (upstream mixed public-domain/BSD/GPL terms) and Zstandard (BSD/GPL dual licensing); their distribution notices remain installed under `/usr/share/doc`. They are invoked as separate programs. Ruby CSV uses Ruby/BSD-2-Clause licensing and is an explicit dependency.

The adapters implement CCI-UI's read-only diagnostics. They do not redistribute
vendor programs, alter TLS trust for the application, or claim vendor endorsement.

## Additional Chrome policy

`CCI_CHROME_POLICY_ENABLED=false` independently controls an additional layer and
requires `CCI_TRUST_CHROME_ENABLED=true`. Its check interval is
`CCI_CHROME_POLICY_INTERVAL=86400`. It shares the selected Chrome release's roots
and schema, with separately scheduled signed CT metadata:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CCI_CHROME_POLICY_TARGET` | `v3` | Supported Google CT log-list format |
| `CCI_CHROME_POLICY_UPDATE_INTERVAL` | `86400` | CT source refresh interval, seconds |
| `CCI_CHROME_POLICY_MAX_AGE` | `604800` | Maximum signed publication and cache age, seconds |

The supported classical X.509 schema is the one shipped with Chrome
`154.0.8037.57`, SHA-256
`79fc7fd7fa70b6337405e0fb7639e1621f66618b144930cf59ce630538b105be`.
An unrecognized schema or trust-affecting field produces unknown. Roots are bound
by certificate SHA-256, never display name. Every field within a constraint set
must pass; one accepted alternative set suffices. Implemented rules cover:

- Inclusive minimum and exclusive maximum browser versions, including partial versions.
- All DNS SANs within the permitted DNS subtrees, including strict subdomain constraints.
- Inclusive validity-start upper bounds and exclusive lower bounds.
- Root expiry and X.509 constraint enforcement according to the anchor's flags.
  Chrome baseline path construction also honors these flags; other profiles retain
  their normal isolated X.509 validation. Non-anchor certificate constraints remain enforced.
- SCT upper-bound rules and rules requiring all verified SCTs after a boundary.
  MTC index fields are ignored for classical X.509 as specified by the schema.

The [signed CT log list](https://googlechrome.github.io/CertificateTransparency/log_lists.html)
and its signature are downloaded from `https://www.gstatic.com/ct/log_list/v3/`.
The fetched signing key must match SPKI SHA-256
`f1d8b68e50210d8e73d9a3e97f571773c52d7f28c0b1a71beee81d8562e6fd85`;
the RSA/SHA-256 signature covers the exact JSON bytes. The list version, signed
publication time and source verification time are retained. Unknown formats, key
rotation, altered signatures and stale lists cannot become verified evidence.
A mismatched list/signature pair is discarded for the next bounded retry. Updates
are atomic and use the same shared durable cache, freshness rules and lease fencing
as trust profiles. New Chrome or CT data invalidates previous policy results.

Embedded RFC 6962 v1 SCTs are parsed with length bounds and verified over the
reconstructed precertificate, the actual issuer SPKI hash and SCT extensions.
RSA/SHA-256 and ECDSA/SHA-256 signatures are supported. Log IDs are checked against
their public keys. Qualified, usable and readonly logs are eligible; retired logs
require an embedded timestamp strictly before retirement. Pending/rejected logs
are excluded. The log's temporal interval applies to certificate expiry, and
future SCTs are rejected. Both ordinary and tiled log entries in the signed list
supply keys. See the [official log-state semantics](https://googlechrome.github.io/CertificateTransparency/log_states.html).

Only certificate-embedded SCT evidence is available. Dedicated precertificate
signing-certificate reconstruction, TLS/OCSP-carried SCTs and live-server probes
are not implemented. If the available verified evidence cannot satisfy a required
SCT rule, the result stays unknown where unavailable external evidence could
change the answer. A verified timestamp violating an all-after rule is conclusive.
Malformed or unverifiable evidence never supplies an accepted timestamp. CA
certificates retain baseline anchor/path evaluation; leaf-specific additional
rules are not applied to them and report not applicable.

When enabled, the displayed `Chrome CA trust` status combines baseline and policy:
a successful baseline cannot remain green while the policy is pending, stale,
unknown or rejected. Details retain the successful baseline, selected path and
policy outcome. When disabled, its row is hidden and Chrome is explicitly labeled
baseline-only. Neither this layer nor its CT metadata is a full Chrome verifier,
full CT compliance check, CRLSet implementation or platform-policy simulation.
The CT list is used solely for offline diagnostics/auditing under its published
usage policy, never to enforce application TLS connections or submit certificates.
