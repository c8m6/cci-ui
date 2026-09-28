# Deferred certificate diagnostics collector plan

Status: deferred, not implemented. Discussion recorded on 2026-09-28.

This document preserves the agreed direction, proposals and unresolved questions
for a later discussion. It does not authorize implementation or describe an
available deployment mode. It was saved at the user's explicit request as an
exception to the repository convention against retaining task plans.

For current behavior, see [certificate diagnostics](certificate-diagnostics.md).

## Motivation and constraints

CCI contains sensitive data and must operate where Internet access is blocked by
default. Proxy exceptions require individual destination approval. A TÜV assessment
is required, but its exact criteria are not yet known.

Approved transfer paths and separate network segments exist. CCI must initiate
connections. Connections initiated towards the CCI host are forbidden. Response
traffic on established outbound connections is assumed to be allowed. Internal
HTTPS access is direct, without a proxy.

The feature must be portable and independently deployable as an open-source
component, without depending on infrastructure specific to one operator.

## Agreed direction

- Run a separate collector on its own host using Docker and a dedicated
  `docker-compose.yml`.
- Serve collected data over HTTPS. CCI initiates downloads. The collector host
  must accept HTTPS from the CCI network, while CCI requires no inbound connection.
- Exclude Artifactory from this design.
- Do not build a dedicated OCSP responder as part of the collector.
- When collector mode is enabled, obtain external diagnostic data exclusively
  through the collector. Never silently fall back to direct Internet requests.
- Aim to cover as many existing checks as possible. Certificates from arbitrary
  internal and public issuers may be present.
- Target daily updates. Real-time updates are unnecessary, but evidence expiry
  must still be respected.
- Defer implementation until the remaining questions have been answered.

The restriction concerns external certificate-diagnostic traffic. Existing
connections to PostgreSQL, Consul and other internal dependencies remain subject
to their own network permissions.

## Proposed architecture, not yet finalized

```text
Public sources
    ^ downloads initiated by the collector through its approved egress path
Collector host with dedicated Docker Compose deployment
    ^ HTTPS downloads initiated by CCI
CCI indexer in the protected network
```

Separate collection and HTTPS serving into services within the Compose deployment.
The serving component should have read-only access to published snapshots. A static
endpoint is sufficient for snapshot distribution.

The collector would acquire public source data on an independent schedule. It should
have no access to CCI's database, Consul credentials, private keys, encryption secrets
or certificate inventory. CCI should not be able to submit arbitrary URLs, bodies or
headers that cause external requests.

CCI would continue evaluating certificates locally. It should independently verify
applicable original signatures, certificate/issuer associations and freshness.
The intended separation is between acquisition and evaluation, not blind acceptance
of collector verdicts. This interpretation still needs confirmation.

Publish complete snapshots atomically. Preserve original files, source notices and
upstream signatures. A versioned manifest should identify source URLs, targets,
releases, hashes, original acquisition times, available signed publication times and
expiry information. Signing the manifest and establishing its verification key
independently of the download are proposed protections, not finalized choices.

Downloading a snapshot again must not reset the age of old evidence. Failed updates
may retain the last valid snapshot for history and availability. Expired material
must not produce a current positive result. Alerting and retention remain open.

Enforce CCI's diagnostic Internet restrictions outside the application. Include DNS,
management paths and shared credentials in the threat model. Container separation
alone is not proof of an adequate security boundary.

## Diagnostic coverage

| Data or check | Proposed treatment | Remaining limitation |
| --- | --- | --- |
| Chrome, Firefox, Edge, Apple and Ubuntu trust | Collect original data and required metadata, publish snapshots, evaluate locally | License review, supported targets and source changes |
| Additional Chrome policy / CT | Transfer list, signature and signing key together, preserve local verification | Usage terms and freshness |
| CRLs | Collect explicitly configured issuer distribution points | Arbitrary issuers prevent a universally complete fixed source list |
| OCSP | Propose disabling OCSP in collector mode initially | Not accepted yet and reduces revocation coverage |

Not building an OCSP responder does not settle whether upstream requests should be
relayed. Relaying would require certificate-specific communication and a separate
design. It is not part of the agreed static distribution model. An existing internal
OCSP service was mentioned, but its issuer coverage is unknown and the latest
direction does not make it a dependency.

Without a supported, valid CRL or available OCSP evidence, revocation status must
remain unknown. CRLs are not a universally equivalent replacement for OCSP. Daily
scheduling does not override an earlier `nextUpdate` or other expiry boundary.

## Open questions for resumption

1. **OCSP scope:** Is disabling OCSP in collector mode acceptable? Otherwise, which
   certificate-specific communication is permitted, and through which service?
2. **CRL sources:** Can operators maintain an explicit URL allowlist? How should
   new issuers be reported and approved? The proposal rejects arbitrary downloads
   automatically triggered by certificate URLs.
3. **HTTPS and authentication:** Is a TLS endpoint or reverse proxy available?
   Should access use mTLS, tokens or network restrictions? Which CA authenticates
   the endpoint, and how are credentials and trust material rotated?
4. **Hosting and ownership:** Where will the collector run, which approved external
   destinations can it reach, and who handles failed updates and source changes?
5. **Update policy:** Who approves new browser targets? Refreshing a pinned release
   and advancing to another release must be distinct operations. What alerting,
   outage tolerance, retention and emergency refresh procedures are needed?
6. **Audience:** Are downloaded data served only within one organization or also
   to third parties? Publishing collector code is distinct from redistributing data.
7. **Assessment:** Which TÜV criteria and existing security concept apply? What
   evidence is required for isolation, integrity, logging, change approval and tests?
8. **Packaging and interface:** Should the collector have its own Git repository?
   Finalize snapshot versioning, paths, configuration and signing-key lifecycle.
   No new environment-variable contract has been agreed.
9. **Evaluation boundary:** Confirm that CCI still validates downloaded evidence and
   evaluates certificates locally, while the collector only acquires source data.

## Licensing findings to revisit

These preliminary findings are not a complete legal clearance for the exact
artifacts to be published. Internal deployment and runtime downloads do not
remove applicable license or usage obligations.

| Source | Preliminary finding and follow-up |
| --- | --- |
| CCADB | CDLA-Permissive-2.0 permits redistribution under its conditions. Include the license text and attribution required by CCADB's usage terms. |
| Firefox/NSS | `certdata.txt` carries MPL-2.0. Preserve notices, license information and access to relevant source form when distributing transformed material. |
| Chromium | BSD-style project license. Review exact rootstore artifacts and third-party notices before approving a public bundle. |
| Ubuntu | Components have differing licenses, including GPL and MPL. Review the exact Ubuntu package and applicable source-availability obligations for binaries. That review is incomplete. |
| Apple | Blanket redistribution permission for the complete selected archive has not been established. Clarify rights before public redistribution. This is an open question, not a finding of prohibition. |
| Chrome CT | Caching is encouraged for supported uses including auditing. CT enforcement in other TLS clients is restricted. Unrestricted public redistribution has not been established. |
| CRLs / OCSP | Conditions depend on the issuer and service. Cacheability alone does not establish public redistribution permission. |

Project-owned code would follow `AGPL-3.0-only`. Third-party data retain their own
terms and must not be presented as uniformly relicensed under AGPL. Proposed images
should initially contain collector code, with external data downloaded at runtime
and their provenance and notices retained.

References consulted during the discussion:

- [CCADB usage terms](https://www.ccadb.org/rootstores/usage)
- [CDLA-Permissive-2.0](https://cdla.dev/permissive-2-0/)
- [Mozilla Public License 2.0](https://www.mozilla.org/en-US/MPL/2.0/)
- [NSS certdata.txt](https://raw.githubusercontent.com/mozilla-firefox/firefox/main/security/nss/lib/ckfw/builtins/certdata.txt)
- [Chromium license](https://raw.githubusercontent.com/chromium/chromium/main/LICENSE)
- [Debian package copyright, not verification of the selected Ubuntu package](https://sources.debian.org/src/ca-certificates/20250419/debian/copyright)
- [Apple security_certificates repository](https://github.com/apple-oss-distributions/security_certificates)
- [Chrome CT usage policy](https://googlechrome.github.io/CertificateTransparency/log_lists.html)
- [RFC 5280: certificates and CRLs](https://www.rfc-editor.org/rfc/rfc5280.html)
- [RFC 6960: OCSP](https://www.rfc-editor.org/info/rfc6960/)
- [TÜVIT security qualification](https://www.tuvit.de/de/leistungen/normen-standards-richtlinien/sicherheitstechnische-qualifizierung-sq/)

## Current implementation boundary and next step

CCI currently downloads diagnostic sources directly or through its diagnostic HTTP
proxy. Source adapters contain upstream locations, and public trust downloads reject
private destination networks. There is no collector mode, snapshot import contract
or internal-mirror configuration yet.

Diagnostics run inside the existing Rails indexer. The Compose template shares
application configuration with it. Diagnostic routines not requiring private keys
does not establish process-level isolation from all sensitive data.

When this topic resumes, resolve the open questions and agree the threat model and
data contract first. Then define implementation work, failure cases, tests,
documentation and any affected screenshot updates. No feature code has been changed
as part of saving this plan.
