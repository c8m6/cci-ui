# Consul schema and writing clients

Consul is the source of truth for new certificates. PostgreSQL contains the
rebuildable search index, including provenance. Direct Consul imports become
visible on the next successful indexing pass (normally within approximately
60 seconds). There is no separate HTTP upload API.

## Setup

1. Configure areas with stable IDs in `config/areas.yml`, for example `zone_a`.
   Every external client must use the same IDs.
2. Provide Consul and set `CONSUL_URL`, `CONSUL_TOKEN`, and optionally
   `CONSUL_PREFIX` (default: `cci/v1`). For TLS, `CONSUL_CA_FILE` can point to
   a CA certificate file.
3. Assign separate ACL tokens to writing clients. Grant write access to the
   required `areas/<area>/lookups/`, `versions/`, optionally `private-keys/`,
   and `events/` paths under the prefix. Reading lookups is required for CAS.
4. For private keys, configure a shared encryption secret per area:
   `<UPPERCASE_AREA_ID>_KEY`, containing 32 random bytes encoded as Base64.
   Writing and decrypting clients must use the same area key.
5. Update PostgreSQL with `ruby bin/rails db:prepare` and start the web and
   indexer services with the new image. `bin/start` runs `db:prepare` automatically.

Consul requires no table migration: clients create the following keys when
writing. Existing Consul entries are not rewritten. The Rails migration adds
the nullable `client` and `created_by` columns to the search index.

## KV structure

All values are JSON objects. The Consul KV and transaction APIs additionally
encode them as Base64 for transport. `<base>` means `<prefix>/areas/<area>`.

| Path | Meaning |
| --- | --- |
| `<base>/lookups/<lookup>` | `{ "entry_id": "<uuid>", "active_version": "<version_id>" }` |
| `<base>/versions/<version_id>` | Public certificate, chain, metadata, and provenance |
| `<base>/private-keys/<version_id>` | Optional AES-256-GCM envelope containing the private key |
| `<prefix>/events/<uuid>` | Audit event for the change |

A lookup contains 1–120 characters from `a-z`, `A-Z`, `0-9`, `.`, `_`, and `-`.
It remains stable across renewals. The `entry_id` is a UUID generated once per
area/lookup pair. The `version_id` is the lowercase SHA-256 hexadecimal digest
of the UTF-8 string `<entry_id>:<fingerprint>`.

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
   for a new lookup. Set `active_version` to the new version ID.
2. Create the version using `cas`, `Index: 0`; never overwrite existing versions.
3. Optionally create the private-key envelope using `cas`, `Index: 0` as well.
4. Create an audit event with a new UUID.

HTTP 409 rejects the entire transaction. Read again and decide how to handle
the conflict; never replace CAS with an unconditional write. The same certificate
under the same lookup is a duplicate; a renewal requires a new certificate.
Values may contain at most 512 KiB, and a transaction may contain at most
64 operations.

Audit fields: `action` (`import`, `activate`, `delete`), `area`, `id` (version ID),
`actor` (acting user), `at` (ISO 8601), and `details` (JSON object).
For imports, `details` contains the previous `previous_version` or `null`,
`tags` as an array, `has_key` as a Boolean, and `certificates` as an array of
snapshots (`common_name`, `subject`, `issuer`, `serial`, `fingerprint`, `source`,
`source_id`, `lookup`, `kind`). The executable example demonstrates this structure.

## Ruby examples

[examples/add_certificate.rb](../examples/add_certificate.rb) works without Rails
or additional gems. It uses the standard library and
[lib/consul_connection.rb](../lib/consul_connection.rb). Both files can be copied
into an external client while preserving their relative directory structure.
Provide credentials and area keys through the runtime environment.

```bash
export CONSUL_URL=https://consul.example.test:8501
export CONSUL_PREFIX=cci/v1
export CCI_CLIENT_ID=acme-renewer
export CCI_ACTOR=svc-acme
# Set CONSUL_TOKEN and optionally ZONE_A_KEY / KEY_PASSWORD through secret management.
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
`ConsulStore.save(area:, cert:, key:, chain:, tags:, lookup:, actor:, client:)`.
The `client:` argument is explicitly required and has no default identifying
the caller as CCI-UI. `CciClient#fetch(..., field: "metadata")` also returns
provenance to Puppet and other Ruby readers when present in the stored version.
