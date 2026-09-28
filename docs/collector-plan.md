# CCI Evidence Gateway

The Evidence Gateway is an optional deployment mode for certificate usage
diagnostics. This document describes the implemented service and its operating
contract. The filename is retained so existing links continue to work.

## Operating modes

| Mode | External diagnostic traffic | Additional services |
| --- | --- | --- |
| Standard (default) | The indexer downloads public trust sources and contacts CRL/OCSP endpoints directly, or through `CCI_DIAGNOSTICS_HTTP_PROXY` when configured. | None |
| Gateway (`CCI_EVIDENCE_GATEWAY_ENABLED=true`) | Web and indexer use HTTPS to the Evidence Gateway for public trust, CRL and OCSP traffic. Only the gateway contacts external diagnostic destinations. A gateway error cannot trigger direct access. | Gateway and Nginx |

Other connections, including PostgreSQL, Consul, Keycloak and PuppetDB, retain
their own network configuration. The gateway does not receive their credentials,
the certificate inventory, area keys or private keys. Certificate imports and
ordinary application readiness do not depend on the gateway.

CCI initiates every gateway connection. The gateway never connects to CCI. The
gateway fetches original public artifacts and CRLs at
`CCI_EVIDENCE_REFRESH_INTERVAL` (default 86400 seconds), initially for enabled
trust profiles and approved CRL URLs and then for previously requested URLs.
The Ubuntu package URL is learned from the signed package index by CCI and fetched
on its first request. OCSP requests are relayed only on demand to the configured
responder URL. No general HTTP proxy or internal OCSP approval service exists.

CCI evaluates trust paths and verifies signed OCSP/CRL bytes locally. The
gateway's cached bytes and timestamps are transport data, never a verdict. CCI
keeps original source bytes and notices in PostgreSQL; CRL and OCSP evidence
also retains original response bytes, URL, acquisition time and SHA-256. The
gateway stores content-addressed bytes and acquisition times on its own volume.
A failed refresh may retain old bytes for history but does not reset their age.
CCI rejects expired material according to signed `nextUpdate`, source maximum
age and certificate validity transitions, regardless of the refresh interval.
A CRL reaching `nextUpdate` is due for a gateway refresh even before the base
interval; CCI requests it at the boundary. Newly added certificates are
scheduled by the existing indexer logic.

`CCI_OCSP_INTERVAL`, `CCI_CRL_INTERVAL`, trust-profile `_INTERVAL` and
`CCI_CHROME_POLICY_INTERVAL` remain local per-certificate check schedules. OCSP
network requests occur only when an OCSP check is due. They have a different
purpose from `CCI_EVIDENCE_REFRESH_INTERVAL`. Source-specific
`_UPDATE_INTERVAL` settings were removed; the single refresh interval replaces
them in both modes. Direct mode retains its previous default check and source
refresh cadence. `_MAX_AGE` and `CCI_DIAGNOSTICS_EVIDENCE_MAX_AGE` are evidence
validity limits rather than download schedules.

## Gateway boundary and limits

Nginx terminates HTTPS and requires a client certificate signed by a dedicated
client CA. It forwards only `/v1/evidence` to the gateway's internal HTTP port.
The backend is on a separate Compose network and is not published to the host.
It accepts three operation types:

- `source`: exact official artifact paths for the selected Chrome and Firefox
  releases, pinned Apple source, CCADB reports, Ubuntu metadata/package path,
  and Chrome CT list and signature;
- `crl`: exact URLs from `CCI_EVIDENCE_CRL_URLS`;
- `ocsp`: exact URLs from `CCI_EVIDENCE_OCSP_URLS`, with a bounded DER request.

The responder lists are JSON arrays of complete HTTP(S) URLs. Unlisted issuers
yield an unknown result in CCI. Add their URLs deliberately on the gateway host,
then restart it. Redirects must also satisfy the same operation's target policy.
The gateway checks every resolved address, blocks loopback, link-local, metadata
and other reserved ranges, and pins the validated address for the connection.
`CCI_EVIDENCE_ALLOWED_NETWORKS` can grant specific internal responder CIDRs, but
never bypasses the exact URL list. Its default is empty. Use firewall and DNS
policy as additional controls; container separation alone is not an egress proof.

The gateway bounds incoming requests to 32 KiB, OCSP bodies to 16 KiB,
downloaded responses to 20 MiB, cache entries to 1500 and request timeouts to
10 seconds (3 seconds to connect). CCI retains its smaller revocation response
limit and separate source expansion limit. Compressed responses are rejected.
No URL, response body, client key or token is logged by the gateway service.
The original upstream URL and bytes are retained as evidence in its cache.

## TLS material and access

Issue a server certificate whose SAN matches the URL used by CCI
(`evidence-nginx` on one Compose host, or the gateway DNS name on separate
hosts). Issue a client certificate with client-auth usage from a dedicated client
CA. Keep keys and CA material outside the repository and images. Mount these
files read-only:

| Directory | Files | Consumer |
| --- | --- | --- |
| `CCI_EVIDENCE_TLS_DIR` | `server.crt`, `server.key`, `client-ca.crt` | Nginx |
| `CCI_EVIDENCE_CLIENT_DIR` | `ca.crt`, `client.crt`, `client.key` | CCI web and indexer |

`ca.crt` must trust the Nginx certificate. The client key must be readable by
application UID 10001. Rotate certificates through the deployment secret system
and recreate affected containers. Nginx validates the client CA; use a separate
CA or rotate it when revoking a client because this example does not configure a
client-certificate revocation list. Restrict network reachability too, without
using fixed client IPs as the only access control.

## One-host Compose example

Set `CCI_EVIDENCE_CLIENT_DIR` and `CCI_EVIDENCE_TLS_DIR` to protected directories
outside the checkout. Set `CCI_EVIDENCE_CRL_URLS` and `CCI_EVIDENCE_OCSP_URLS`
as needed. Use the same enabled trust checks and Chrome/Firefox targets for CCI
and the gateway. Then start the opt-in override:

```bash
docker compose -f compose.yml -f compose.evidence.yml up --build -d --wait
```

Nginx is reachable as `https://evidence-nginx` only on the Compose application
network; its certificate must cover `evidence-nginx`. The gateway backend is
reachable only from Nginx on `evidence_backend`.

## Separate-host Compose example

On the gateway host, deploy this repository or import its published application
image, provide the server TLS directory, configure exact responder allowlists,
and publish HTTPS through the host firewall:

```bash
docker compose -f compose.evidence-remote.yml up --build -d --wait
```

On the CCI host, set `CCI_EVIDENCE_GATEWAY_URL` to that host's HTTPS origin, set
`CCI_EVIDENCE_CLIENT_DIR`, and start CCI with the client override:

```bash
docker compose -f compose.yml -f compose.evidence-client.yml up --build -d --wait
```

Use the production base Compose file in place of `compose.yml` for production
CCI. Web and indexer need only outbound HTTPS to the gateway for diagnostic
traffic. The gateway needs egress to the selected official source hosts and
approved CRL/OCSP destinations. Keep its `evidence_data` volume; CCI's
PostgreSQL backup contains its own evidence cache.

If the gateway is unavailable, CCI reports unknown and keeps any still-valid
previous result with its original expiry. There is no direct fallback. Missing
or expired evidence never becomes a current green result. Monitor gateway
availability, disk usage and CCI diagnostic staleness independently.

## Provenance and redistribution

Gateway code and configuration are project-owned under `AGPL-3.0-only`.
Third-party source files are downloaded at runtime and retain their terms and
notices; the image does not bundle them. Do not publish cached vendor artifacts
without reviewing their exact redistribution conditions. The separate
[NGINX Open Source image](https://github.com/nginx/nginx) uses a 2-clause
BSD-like license. Source-specific limitations and notices remain in
[certificate diagnostics](certificate-diagnostics.md#provenance-and-licenses).

This deployment does not supply a network isolation proof, a complete browser
policy verifier, a universal CRL list or a guarantee that every public issuer's
OCSP endpoint is approved. Review allowlists, egress rules, certificate rotation
and assessment requirements for the target environment.
