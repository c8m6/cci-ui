> Historical proposal, superseded by the confirmed requests in `aenderungen.txt`.
> Current documentation: [Architecture](technik.md), [Installation](installation.md), [Puppet](puppet.md).
> In particular, Consul replaced Redis and the export permission model changed.

# Certificate management: requirements and architecture proposal

As of 11 September 2026. Based on analysis of `quelle/certifactory` and `data`,
and on the project owner's answers. This document describes the planned scope;
it is not evidence of completed functionality. Technical proposals and open
decisions are explicitly identified. Area names below are neutral examples.

## Confirmed requirements

- Support the file system and Redis concurrently and search them together.
- Keep legacy files in their existing location without migration.
- The collection supplied in `data` is an example belonging entirely to one
  permission area; it contains no samples for the other area.
- Save uploads only to Redis, using a newly defined data model.
- Preserve Puppet's existing file access through an NFS share on the compilers
  and retain existing Hiera settings.
- Puppet should retrieve new certificates directly from Redis.
- Import and export PEM, DER, PKCS#12/PFX and JKS: individual certificates,
  certificate chains, private keys and bulk downloads.
- Search CN/subject, SAN domains and IP addresses, issuer, serial number,
  fingerprint and tags; filter by expiration and private-key availability.
- Two independent permission areas, each with Reader and Writer roles.
  Readers must not export private keys.
- Keycloak is available for SSO and must be optional for local testing.
- Run in Docker on a VM, with around ten concurrent requests and up to 80 users.
- An additional database is permitted.
- Application logic must use Ruby, without Bash. JavaScript is allowed for UI
  interaction.
- Provide a modern German UI without inheriting previous design constraints.

## Findings from the legacy application

The existing application uses Node.js/Express, AngularJS and Bash scripts.
It reads files from `data/certmgr`, while the supplied example collection sits
directly in `data`. The new read path must therefore be configurable. For local
evaluation, the example path is assigned to a designated area. Production file
sources receive an explicitly configured path and area; the sample path is not
assumed to be a production location. The supplied code contains no Redis
integration.

Storage paths use hashes of issuer and subject, including an optional tag.
The UI generates Hiera settings with `issuer` and `subject`. The actual Puppet
implementation is not included. Its exact name normalization and lookup rules
must be checked before integration. Existing paths must not be regenerated
from newly normalized names.

The collection contains 1,585 PEM files, 1,017 associated key files and 304 tag
files. The PEM files contain 1,673 certificate blocks representing 1,546 distinct
certificates. Thirty files contain multiple certificates; one also contains a
private key. Three tag files have no PEM file with the same name. Ninety-four
issuer/subject combinations contain multiple distinct certificates. These
figures describe the analyzed collection, not a guaranteed production size.

Existing search is a browser-side filter on subject and tag only, combining
terms with OR. Details contain copyable PEM text; no complete download flow is
apparent. Existing JKS helpers are not connected to the server. In the visible
import flow, PKCS#12 is processed in the browser and reduced to the first
certificate and first key. The new implementation must process all supported
entries.

## Technical proposal

Ruby on Rails provides HTML, application logic and the API. Hotwire with Turbo
and Stimulus handles navigation, search updates and upload interaction. CSS
defines an independent, consistent design. Ruby and library versions will be
selected and pinned according to support status when the project is set up.
Rails supports this JavaScript integration, including import maps, without a
Node build process: [Rails documentation](https://guides.rubyonrails.org/working_with_javascript_in_rails.html).

PostgreSQL stores the combined search index, area assignments, SSO mappings and
the proposed change log. Exact filters use normalized fields; text search uses
suitable indexes. `pg_trgm` supports indexed substring and similarity search:
[PostgreSQL documentation](https://www.postgresql.org/docs/17/pgtrgm.html).
Private keys must not enter the search index.

Redis is the source of truth for new certificates and keys. A file adapter
reads legacy data. Indexing metadata does not migrate original files into Redis.
Source references are preserved even if the same fingerprint occurs in several
locations.

For the first implementation, legacy files will be mounted read-only. Whether
the new UI should delete old files or change their tags remains open. Uploads
will always be written to Redis regardless of that decision.

A Ruby background process updates the index at startup, periodically and on
request. Exports recheck permissions and read from the relevant source. Missing
or changed source data produces a clear error. A stale index must not grant
permissions that have since been revoked.

## Proposed Redis model

Use the versioned namespace `certui:v1`, area IDs and UUIDs for management entries.
An entry contains multiple immutable certificate versions. SHA-256 of the DER
representation identifies certificate contents; a subject or domain alone does
not uniquely identify a renewal.

| Key pattern | Type | Purpose |
| --- | --- | --- |
| `certui:v1:area:<area_id>:entries` | Set | Entry IDs in an area |
| `certui:v1:area:<area_id>:entry:<entry_id>` | Hash | Schema version, name, tags as JSON, timestamps, active version ID and revision |
| `certui:v1:area:<area_id>:entry:<entry_id>:versions` | Sorted Set | Version IDs ordered by creation time |
| `certui:v1:area:<area_id>:version:<version_id>` | Hash | Entry ID, PEM certificate, chain as a JSON list of PEM certificates, fingerprint, origin and timestamps |
| `certui:v1:area:<area_id>:private-key:<version_id>` | Hash | Encrypted key, key version and cryptographic parameters |
| `certui:v1:area:<area_id>:fingerprint:<sha256>` | Set | Version IDs for duplicate detection within an area |
| `certui:v1:area:<area_id>:lookup:<lookup_id>` | String | Entry ID for a stable, explicitly assigned Puppet lookup |
| `certui:v1:events` | Stream | Changes for recoverable indexing and logging, without key material |

Duplicate uploads are detected through fingerprints and do not silently
overwrite existing versions. Renewal explicitly selects an existing entry.
The exact versioning, archiving and deletion behavior still requires confirmation.

Redis changes and their associated events are written in a Redis transaction;
revisions detect concurrent modifications. The indexer processes events
idempotently and acknowledges them only after a successful PostgreSQL commit.
Periodic reconciliation repairs discrepancies. No shared transaction between
Redis and PostgreSQL is assumed.

Private keys should use authenticated encryption before storage. Direct Puppet
access requires decryption on authorized compilers as well. Proposed approach:
separate, versioned encryption keys per area, supplied as secrets outside Redis.
The web application receives the required area keys; each compiler receives only
those needed for its areas. The format and rotation procedure will be implemented
alongside the Ruby Puppet reader. Decryption secrets must not appear in catalogs
or logs. A master key known only to the web application would be incompatible
with direct Puppet access.

Redis will use persistent volumes, AOF and additional snapshots, with automatic
eviction of certificate data disabled. The operations design will define the
exact fsync behavior. AOF and RDB offer different durability and recovery
properties: [Redis persistence documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/).

## Permissions and integration

Permissions apply per area, independently of the data source. File system and
Redis are not permission areas. A person may be a Writer in one area and a
Reader in another. No assignment means no access. The same server-side rules
restrict results, counts, suggestions, details, chains and bulk downloads.

Readers search, view details and export public certificates, never private keys.
The proposed Writer role additionally permits import, management and private-key
export within its area. Chain certificates must not implicitly bypass area
boundaries.

For legacy files in particular, certificate exports are serialized from parsed
X.509 objects. Readers never receive an unchecked original file because PEM
files can contain embedded private keys. The same rule applies to previews,
API responses, error messages and bulk downloads.

The proposed Keycloak integration uses OpenID Connect, including discovery:
[Keycloak documentation](https://www.keycloak.org/securing-apps/oidc-layers).
Configurable group/role mappings provide Reader and Writer roles per area,
such as `zone_a_reader`, `zone_a_writer`, `zone_b_reader` and `zone_b_writer`.
These are application roles; actual Keycloak group names remain to be determined.

Local testing uses an explicit development mode without Keycloak. It supplies
test identities for the roles and cross-area combinations while retaining all
normal authorization checks. Production rejects this mode at startup. A Keycloak
outage or misconfiguration must never switch automatically to development mode.

Puppet receives independent machine credentials, separate from Keycloak and
interactive Reader/Writer roles. New certificates are read directly from Redis;
neither the web application nor PostgreSQL is required for a compile. Legacy
access retains its existing NFS path and unchanged Hiera settings.

Each required area receives separate Redis credentials restricted to the
necessary read commands and key prefixes. No blanket access to every area or
to administrative commands is granted. Redis supports ACLs for commands and
key patterns: [Redis ACL documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/).
Network access and transport encryption are configured for compilers and the
application. Machine authorization for private keys is distinct from a UI
user's Reader role.

A small Ruby reader on the compilers uses a versioned Redis contract: area and
stable lookup resolve to an entry ID, which resolves to the active version.
Certificate, chain and key are then read through the same immutable version ID.
Explicit version pinning is planned. The read path requires no KEYS/SCAN search
through the collection. Connections are reused, and data is cached for at most
one compile. Timeouts and errors for missing entries, missing permissions and
Redis outages are defined; no silent fallback to a different certificate occurs.

This approach avoids an additional runtime dependency on the web application.
It requires compatible versioning of the Redis schema, encryption format and
reader. Actual load must be tested against compiler counts, simultaneous
compiles and certificate requests; ten concurrent UI requests are not a
sufficient measure. An API would simplify centralized authorization and
decryption, but is not a required component for the current use case.

## Import, export and UI

Import provides file selection, drag-and-drop and PEM input, area selection,
a password field for protected files and a preview before saving. The preview
shows every recognized certificate, chain, key association, duplicate and error.
Keys are checked against certificates. Passwords and key material are not logged.

Ruby OpenSSL supports PKCS#12 processing:
[Ruby OpenSSL documentation](https://ruby.github.io/openssl/OpenSSL/PKCS12.html).
JKS is a separate keystore format that supports, among other things, distinct
store and individual-key passwords:
[Oracle documentation](https://docs.oracle.com/en/java/javase/12/tools/keytool.html).
Before implementing formats, a Ruby proof of concept is required for JKS and
containers holding multiple key pairs. JKS remains part of the confirmed scope;
a Java or Bash fallback has not been agreed.

The initial view is a sortable, paginated certificate list with search, visible
filters and selection for bulk downloads. Each entry shows its source as legacy
files or Redis, separately from its permission area. Expiration status uses
both text and color. Details show SANs, issuer, validity, fingerprints, key
availability, chain and versions. Interaction accounts for keyboard access,
focus management and readable contrast.

The proposed default search combines terms with AND. CN/SAN matches rank ahead
of weaker text matches. Fingerprints and serial numbers receive separate
normalization. Validity filters distinguish not-yet-valid, valid, expiring-soon
and expired certificates. A complete chain can only be exported if its components
are available and accessible; missing components are indicated.

## Implementation and acceptance

1. Implement the confirmed area model and resolve open integration questions;
   verify JKS/PKCS#12 feasibility with synthetic test certificates.
2. Set up Rails and Docker with PostgreSQL and Redis.
3. Implement both sources, the metadata index, and German search/detail views.
4. Implement import, versioning and every agreed export format.
5. Integrate SSO, area permissions and Puppet; require authorization for all
   endpoints from step 2 onward.
6. Test restarts, recovery, concurrent changes and ten simultaneous requests;
   determine index sizing from the still-unknown maximum certificate count.

Key acceptance criteria: no writes to legacy data in read-only mode; uploads
only to Redis; no results or exports from unauthorized areas; format round trips
including key association; preservation of existing Hiera lookups; recoverable
indexing; and no secrets in logs. Tests use generated data, not copied legacy
private keys.

## Open questions

1. Keycloak realm, client and available group/role claims for later integration;
   local tests do not need this information.
2. Existing Puppet lookup code, Puppet/Ruby versions on the compilers, compiler
   count and expected request load for integration tests.
3. Confirmation of proposed versioning, tag management and deletion rules,
   especially for legacy files; requirements for change/export audit logs.
4. Expected upper bound on certificate count and changes made by other systems.
