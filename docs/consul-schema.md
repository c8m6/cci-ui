# Consul schema and writing clients

Consul is the source of truth for imported certificates and their lookup status
and archive state. PostgreSQL contains the search index, including provenance
and cached PuppetDB host associations. Filesystem certificates remain read-only
catalog entries without mutable status or archive state. Rebuilding the index
requires the original sources; back up PostgreSQL to retain entries whose
material is no longer available. Direct Consul imports become
visible on the next successful indexing pass (normally within approximately
60 seconds). There is no separate HTTP upload API.

## Setup

1. Configure area IDs and labels in the `CCI_AREAS` JSON environment variable,
   for example `CCI_AREAS='{"zone_a":"Zone A"}'`.
   Every external client must use the same IDs.
2. Provide Consul and set `CONSUL_URL`, `CONSUL_TOKEN`, and optionally
   `CONSUL_PREFIX` (default: `cci/v1`). For TLS, `CONSUL_CA_FILE` can point to
   a CA certificate file.
3. Assign separate ACL tokens to writing clients. Grant write access to the
   required `areas/<area>/lookups/`, `versions/`, optionally `private-keys/`,
   and `events/` paths under the prefix. Reading lookups is required for CAS.
   Neither service needs access to historical `filesystem-statuses/` keys.
4. For private keys, configure a shared encryption secret per area:
   `CCI_AREA_KEYS='{"zone_a":"<Base64 key>"}'`, with 32 random bytes per area.
   `<UPPERCASE_AREA_ID>_KEY` remains an alternative process variable.
   Writing and decrypting clients must use the same area key.
5. Update PostgreSQL with `ruby bin/rails db:prepare` and start the web and
   indexer services with the new image. `bin/start` runs `db:prepare` automatically.

Consul requires no table migration: clients create the following keys when
writing. Existing Consul entries are not rewritten. Rails migrations add the
status/archive projections and optional PuppetDB inventory fields. Migration
`20260916000400` clears obsolete filesystem status/archive projections locally
and constrains filesystem rows to their read-only defaults. Run a complete index pass
(`ruby bin/rails runner 'CatalogIndexer.run'`) after upgrading or wait for the
indexer. Discard import previews opened before deployment and create new ones.

## KV structure

All values are JSON objects. The Consul KV and transaction APIs additionally
encode them as Base64 for transport. `<base>` means `<prefix>/areas/<area>`.

| Path | Meaning |
| --- | --- |
| `<base>/lookups/<lookup>` | `{ "entry_id": "<uuid>", "active_version": "<version_id>", "status": "active" }` |
| `<base>/versions/<version_id>` | Public certificate, chain, metadata, and provenance |
| `<base>/private-keys/<version_id>` | Optional AES-256-GCM envelope containing the private key |
| `<base>/filesystem-statuses/<fingerprint>` | Historical only; ignored and never written by the application |
| `<prefix>/events/<uuid>` | Audit event for the change |

A lookup contains 1–120 characters from `a-z`, `A-Z`, `0-9`, `.`, `_`, and `-`.
It remains stable across renewals. The `entry_id` is a UUID generated once per
area/lookup pair. The `version_id` is the lowercase SHA-256 hexadecimal digest
of the UTF-8 string `<entry_id>:<fingerprint>`.

### Lookup and Puppet status

| Field | JSON type and contents |
| --- | --- |
| `entry_id` | UUID string identifying this area/lookup pair |
| `active_version` | String containing the selected version ID |
| `status` | String: exactly `active`, `norollout`, or `delete`; case-sensitive |
| `archived` | Optional Boolean; absent means `false`. `true` requires `status: delete`. |
| `archived_at`, `archived_by` | ISO 8601 timestamp and actor recorded when archiving |

`status` belongs to the lookup, not to an immutable version. All historical
versions display the same current status. Imports and version activation must
preserve the existing status and other lookup fields. A new lookup starts with
`active`. An older lookup without `status` is interpreted as `active`; explicit
unknown values, including `null` and empty strings, are rejected by the UI
services and Ruby reader. The index's Boolean `active` means “selected version”
and is independent of the string `rollout_status` and X.509 validity.

| Status | Contract for future Puppet processing |
| --- | --- |
| `active` | Deploy the configured certificate normally, including recreation if missing. |
| `norollout` | Do not create or recreate certificate/key files and leave existing files unchanged. |
| `delete` | Actively remove managed certificate/key files, including when the certificate is no longer configured in Hiera. |

This release implements storage, editing, filtering, audit, and reader metadata
only. The supplied Puppet manifests **do not enforce these statuses yet**.
Setting `delete` neither deletes Consul material nor removes local files.
Keep the lookup and status record so a future consumer can still discover the
removal request. Physical deletion through the UI has been removed; stored
versions and keys remain available after archiving.

### Legacy certificate status

Filesystem certificates have no mutable Puppet status or archive state. They
remain indexed in the PostgreSQL UI catalog, with their source marked as
`filesystem`; their certificate and private-key files remain read-only and are
not copied to Consul. Status controls, activation and archiving are available
only for `consul` records. The overview shows “–” for a filesystem Puppet status;
status filters select only Consul certificates.

Historical `<base>/filesystem-statuses/<fingerprint>` keys from earlier releases
are ignored and retained without modification. They are not instructions for
Puppet. Historical audit events remain readable. Migration `20260916000400`
clears obsolete local filesystem archive/status projections so previously hidden
filesystem entries become visible again. The local `active` status default is
an internal placeholder, not a Puppet rollout directive for filesystem records.

`CCI_LEGACY_PATHS` maps configured area IDs to directories. Catalog identity
includes area, source, relative file/block ID and SHA-256 fingerprint. Replacing
a file retains its old entry; moves may leave multiple catalog records. Empty,
missing or partially unavailable mounts and removed mappings never delete
catalog entries. Removing a mapping blocks material access through it.
A missing or unreadable inventory, unsafe symlink or malformed certificate
reports an error for that area while other sources continue indexing.

### Archiving

“Archivieren” is available only for Consul certificates, next to “Status speichern”.
It requires area Writer permission and an explicit confirmation of
the affected scope and Puppet deletion request. The server checks confirmation
and the exact `ModifyIndex` seen on the confirmation page. In one Consul
transaction it writes `archived: true`, `status: delete`, `archived_at`,
`archived_by`, and an `archive` audit event. No certificate or key is deleted.
The scope is all versions of a Consul lookup within its area. Filesystem
certificates cannot be archived, including through direct HTTP or service calls.

The archive flag is separate from Puppet status: setting `delete` alone does
not archive an entry. Existing entries default to unarchived. Archived entries
are excluded from the overview and statistics, while nonblank text searches
include them, even historical versions. “Archivierte einschließen” also includes
them without a search term. All normal access and search filters still apply.
The UI does not support reversing archiving; it rejects activation and changes
to a Puppet status other than `delete` for archived entries. Imports under an
archived lookup preserve archive metadata, as must external clients.

Reindexing recovers archive metadata from Consul for source material that still
exists. PostgreSQL backups are required to recover catalog metadata whose source
has disappeared; retaining a catalog row does not preserve the original PEM or
private key. Detail pages show retained metadata when material cannot be loaded.

Status records contain no target file paths;
future Puppet cleanup must retain a per-node inventory of managed certificate
and key paths to remove files after their Hiera entries disappear. Subject and
issuer are descriptive metadata, not unique identifiers or deletion targets.

### Changing status atomically

1. Read the Consul lookup consistently and retain `ModifyIndex` when presenting
   the edit form. Reject filesystem certificate mutations.
2. Validate the requested status and recheck Writer permission for the area.
3. Read again and reject a different index. Preserve `entry_id`, `active_version`,
   archive metadata and all other lookup fields.
4. In one transaction, CAS the status-bearing key against that exact index
   and create a `status_change` event. On conflict, reload before retrying.

The UI does not emit an event for an unchanged status. Every actual change
refreshes the PostgreSQL index after the Consul transaction. Direct client
changes appear on the next indexing pass. This makes status recoverable from
Consul if the search index is rebuilt.

### Certificate version

| Field | JSON type and contents |
| --- | --- |
| `schema` | String `"1"` |
| `entry_id` | UUID string; unchanged for subsequent versions of the same lookup |
| `lookup` | Stable lookup name |
| `pem` | One public X.509 certificate as a PEM string |
| `chain` | **String containing a JSON array** of PEM strings, excluding the certificate itself, immediate issuer first; empty: `"[]"` |
| `tags` | **String containing a JSON array** of tag strings; empty: `"[]"` |
| `fingerprint` | SHA-256 of certificate DER, 64 lowercase hexadecimal characters |
| `public_key_fingerprint` | SHA-256 of SubjectPublicKeyInfo DER (`public_to_der`), 64 hexadecimal characters |
| `has_key` | String `"1"` or `"0"`; `"1"` requires a corresponding private-key envelope |
| `created_at` | Creation time of this stored version as an ISO 8601 string with a time zone |
| `client` | Writing application's identifier; required for new writes, 1–120 characters using the same character set as lookups |
| `created_by` | Initiating user or service account; required for new writes, 1–255 characters, not whitespace-only |

CCI-UI sets `client: "cci-ui"` in its upload path and takes `created_by` from
the authenticated identity. Other applications use their own stable identifier,
such as `acme-renewer` or `inventory-import`. Read requests, for example from
Puppet, do not change the creator. Activating an older version also preserves
that version's provenance.

This is an additive extension of schema `"1"`; the namespace, ID calculation,
and encryption remain unchanged. Existing readers can ignore additional fields.
Older versions without provenance remain readable and display
“Unbekannt (keine Client-Angabe)” (unknown: no client specified). The Consul
storage location alone cannot identify the client. Legacy files are displayed
separately as file-based inventory. New clients must write provenance fields;
Consul itself does not enforce a JSON schema.

These fields are supplied by the writing client and are not cryptographic proof
of authorship. The client is also distinct from the X.509 certificate issuer
(`issuer`). Write permissions and ACL token assignment remain authoritative.

### Private key

```json
{ "version": 1, "iv": "<base64>", "tag": "<base64>", "data": "<base64>" }
```

Here, `version` is a **number**, unlike `schema` in the certificate object.
The private PEM key is encrypted using AES-256-GCM, a fresh 12-byte IV, and the
32-byte area key. The authentication tag contains 16 bytes. AAD is exactly
`cci:v1:<area>:<version_id>`, even when `CONSUL_PREFIX` is customized. Private
keys must never appear in the public version object.

### Transaction and audit

First, read the lookup consistently. Generate a UUID for the first import;
reuse the existing `entry_id` for renewals. Within one transaction:

1. Write the lookup using `cas` with its previous `ModifyIndex`; use `Index: 0`
   for a new lookup. Set `active_version` to the new version ID. New lookups
   receive `status: "active"`; renewals preserve the previous status (default
   `active` only if the field was absent). Preserve other existing lookup fields.
2. Create the version using `cas`, `Index: 0`; never overwrite existing versions.
3. Optionally create the private-key envelope using `cas`, `Index: 0` as well.
4. Create an audit event with a new UUID.

HTTP 409 rejects the entire transaction. Read again and decide how to handle
the conflict; never replace CAS with an unconditional write. The same certificate
under the same lookup is a duplicate; a renewal requires a new certificate.
Values may contain at most 512 KiB, and a transaction may contain at most
64 operations.

Audit fields: `action` (`import`, `activate`, `archive`, `status_change`; historical `delete` events remain readable), `area`,
`id` (version ID; older filesystem events use a legacy `source_id`),
`actor` (acting user), `at` (ISO 8601), and `details` (JSON object).
For imports, `details` contains the previous `previous_version` or `null`,
`tags` as an array, `has_key` as a Boolean, and `certificates` as an array of
snapshots (`common_name`, `subject`, `issuer`, `serial`, `fingerprint`, `source`,
`source_id`, `lookup`, `kind`). The executable example demonstrates this structure.
For `status_change`, `details.previous_status` and `details.status` are the old
and new strings. `details.certificates` identifies the active Consul version at
the time of the lookup-wide status change.
Historical filesystem events remain readable, but new status/archive events are
created only for Consul certificates.
For `archive`, `details` includes the selected certificate snapshot,
`previous_status`, `status: delete`, `previous_archived: false`, `archived: true`,
`scope` (`lookup`; historical filesystem events may use `fingerprint`), and a comment explaining the confirmed
visibility and Puppet effects. The event records the actor and original time.
An already archived scope produces no duplicate archive event.
Audit records contain no private keys or PEM contents.

### UI duplicate prevention against legacy files

Before creating an import preview, the application scans every configured legacy
PEM inventory and compares SHA-256 fingerprints of certificate DER with every parsed
upload certificate. The check applies to pasted PEM and all supported upload
formats, including certificates in bundles. An existing disk certificate rejects
the entire upload, regardless of the requested lookup or destination area.
The error does not expose the legacy path or restricted area metadata. A renewal
with the same subject but different DER is a different certificate and is allowed.

The full check runs again after session, permission, and confirmation validation
at commit, before consuming the draft or writing any certificate to Consul. This
catches disk additions since preview and rejects the entire batch before any
writes. The search index is not used as proof: unindexed files block uploads,
while stale catalog rows for deleted files do not. If the inventory cannot be
fully read in any configured area, the application rejects the upload until
verification is possible. Areas without a legacy mapping are skipped, and
`CCI_LEGACY_PATHS='{}'` disables the disk duplicate check.
Disk changes and Consul writes cannot share an atomic transaction; external disk
changes after the final scan remain a concurrency boundary. External Consul
writing clients without disk access are not covered by this UI check.

### UI overwrite confirmation

An import preview reads each destination lookup directly from Consul and stores
its `ModifyIndex` and `active_version` in the session-bound draft. Existing
lookups are highlighted by area and name. The user must tick
“Ja, ich bin sicher und möchte die oben gekennzeichneten bestehenden Lookups
überschreiben.” before saving; the server enforces the confirmation too.
The old certificate version remains available in history.

At commit, each destination must still have the previewed index. A lookup that
appeared after the preview, or any intervening renewal, activation, or status
change, requires a fresh preview. The final write uses CAS to cover changes
after that check. Unaffected entries in a batch may succeed independently;
errors identify entries that require a new preview. Reimporting identical
certificate DER under the same lookup remains a duplicate even if confirmed.
Confirmation is a UI workflow; noninteractive clients implement their own
renewal authorization and must still use CAS and preserve status.

## Ruby examples

[examples/add_certificate.rb](../examples/add_certificate.rb) works without Rails
or additional gems. It uses the standard library and
[lib/consul_connection.rb](../lib/consul_connection.rb) and
[lib/area_secrets.rb](../lib/area_secrets.rb). These files can be copied
into an external client while preserving their relative directory structure.
Provide credentials and area keys through the runtime environment.

```bash
export CONSUL_URL=https://consul.example.test:8501
export CONSUL_PREFIX=cci/v1
export CCI_CLIENT_ID=acme-renewer
export CCI_ACTOR=svc-acme
# Set CONSUL_TOKEN and optionally CCI_AREA_KEYS / KEY_PASSWORD through secret management.
ruby examples/add_certificate.rb zone_a portal.production certificate.pem
# With a private key:
ruby examples/add_certificate.rb zone_a portal.production renewed.pem private-key.pem
```

To include a chain and tags from your own Ruby code:

```ruby
require_relative "examples/add_certificate"

version_id = CertificateExample.add(
  area: "zone_a", lookup: "portal.production",
  cert: OpenSSL::X509::Certificate.new(File.binread("certificate.pem")),
  chain: [OpenSSL::X509::Certificate.new(File.binread("issuer.pem"))],
  tags: ["Production", "ACME"], client: "acme-renewer", actor: "svc-acme"
)
puts version_id
```

Within the Rails application, a custom importer can instead call
`ConsulStore.save(area:, cert:, key:, chain:, tags:, lookup:, actor:, client:,
expected_lookup_index: nil)`. UI imports supply the previewed index; direct
callers may omit it and use the current lookup index for CAS.
The `client:` argument is explicitly required and has no default identifying
the caller as CCI-UI. `CciClient#fetch(..., field: "metadata")` also returns
provenance to Puppet and other Ruby readers when present in the stored version,
plus `status` from the lookup (including when requesting an explicit version).
Metadata exposes the status without changing certificate/key retrieval behavior.
