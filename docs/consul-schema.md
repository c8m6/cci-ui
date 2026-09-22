# Consul schema and Ruby integrations

The default prefix is `cci`. This document describes the storage contract for
an initial deployment. Consul's `/v1/` HTTP API path is unrelated to the storage
prefix.

Consul holds certificate material and the current selection. PostgreSQL holds
UI audit history and the searchable catalog. Filesystem certificates remain
read-only and have no Consul records.

## KV structure

Let `<base>` be `cci/<area>`. Keys have no leading slash.

The area ID separates inventories, ACL scopes and encryption secrets. The same
CertID can exist independently in multiple areas.

| Path | Value |
| --- | --- |
| `<base>/certids/<certid>` | Selection, version counter, status and last writer |
| `<base>/certs/<certid>/<version>` | One public certificate and its import metadata |
| `<base>/keys/<certid>/<version>` | Optional encrypted private key |

There are no separate chain, provenance, fingerprint or event keys. A CertID
contains 1–120 characters from `a-z`, `A-Z`, `0-9`, `.`, `_`, `-`. An area matches
`[a-z][a-z0-9_]{0,47}` and must be configured in `CCI_AREAS` to appear in the UI.
A version is a positive JSON integer, starting at `1` for each area/CertID pair.
Paths use its decimal representation without leading zeros.

### CertID metadata

```json
{
  "active_version": 3,
  "latest_version": 5,
  "status": "active",
  "updated_at": "2026-09-21T10:00:00.000000Z",
  "client": "cci-ui",
  "updated_by": "user-subject"
}
```

`active_version` selects the current certificate. `latest_version` is the largest
allocated version. After activating version `3` of five stored versions, the next
import creates version `6`. Never infer the selected version from timestamps or
key ordering. Every successful import allocates a version, including a repeated
upload of the same certificate. UI checks against legacy filesystem duplicates
remain in effect.

`client` and `updated_at` identify the most recent writer of this record. UI
writes also set `updated_by` to the authenticated identity. Direct Puppet writes
set `client: "puppet"` and a UTC timestamp, without requiring a human actor.
Writers preserve status, archive metadata and unknown fields during renewal.
`updated_by` identifies the actor responsible for the most recent metadata
change, including imports, activation and status changes. When a machine writer
omits its actor, it must remove any previous `updated_by` value so an earlier
UI user is not credited with the machine's update.

### Certificate version

```json
{
  "pem": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "tags": ["Production"],
  "has_key": true,
  "created_at": "2026-09-21T10:00:00.000000Z",
  "client": "cci-ui",
  "created_by": "user-subject"
}
```

The PEM contains exactly one certificate. Tags are a JSON array and `has_key` is
a Boolean. Fingerprints, subject, issuer, validity and public-key information are
computed from the certificate. The path supplies CertID and version, so they are
not duplicated in the value. There is no UUID or certificate schema field.

`client` and `created_at` are required for new imports. `created_by` is required
for UI writes and optional for machine writers. These fields describe who
imported this immutable version and remain unchanged when another version is
activated. They are supplied by the writer, not cryptographic proof of identity.
Consul ACLs determine who may write.

For machine writers, `client` identifies the software, for example `puppet`.
The optional `created_by` and `updated_by` identify its service account or
machine, for example `svc:puppet-prod` or `puppet:node.example.org`. Use a stable,
non-secret identifier. Do not put ACL tokens, passwords or private keys in these
fields. If no reliable actor is available, omit the fields rather than inventing
a human identity. An actor is a nonblank string of at most 255 characters.

The Ruby writer accepts `actor: "svc:puppet-prod"` and applies it to both fields
on import. The command-line example accepts `CCI_ACTOR`. A machine import with
an actor therefore has `client: "puppet"` and `created_by: "svc:puppet-prod"` in
the certificate version, and `client: "puppet"` and
`updated_by: "svc:puppet-prod"` in the CertID metadata. Later updates leave the
version's `created_by` unchanged.

### Private key

`<base>/keys/<certid>/<version>` contains only an encrypted private key envelope.
The corresponding certificate and its public key are in `certs/`. Plaintext
private keys are never stored in either subtree.

```json
{"version":1,"iv":"<base64>","tag":"<base64>","data":"<base64>"}
```

The envelope encrypts the private PEM with AES-256-GCM, a 32-byte area secret,
a fresh 12-byte IV and a 16-byte authentication tag. AAD is exactly
`cci:<area>:<certid>/<version>`, independent of a customized storage prefix.
The envelope's `version: 1` identifies the encryption format, not the certificate
version. A key must match its certificate. Configure shared secrets through
`CCI_AREA_KEYS` or `<UPPERCASE_AREA_ID>_KEY`.

## Request budget and concurrency

For one certificate import:

1. Read `<base>/certids/<certid>` once, retaining the KV response's `ModifyIndex`.
   If Consul returns HTTP 404, use `0` as the expected index for creation.
2. Submit one `/v1/txn` request: CAS the metadata against that index and create
   the public version and optional private key with `cas`, `Index: 0`.

Thus an import uses **two HTTP requests**: one metadata read and one atomic
write. The transaction contains two or three KV operations. There is no extra
version-existence read, audit write or version-counter request. A conflict
rejects all writes. A retry is a new attempt and must reread metadata. Never
replace CAS with unconditional writes.

`ModifyIndex` is Consul's modification index for the KV entry. It is returned
alongside the Base64-encoded `Value`, outside the stored certificate JSON.
Consul assigns it automatically. It is independent of `active_version` and
`latest_version`, and writers must not increment it themselves.

For example, after reading `ModifyIndex: 4711`, submit the metadata operation
with `Verb: "cas"` and `Index: 4711`. Consul accepts it only if the entry still
has that index. If another writer has changed it, the transaction returns HTTP
409 and none of its writes are committed. Reread metadata and recalculate the
next version before retrying. `Index: 0` requires that the target key does not
exist, protecting both new CertIDs and immutable material versions.

See Consul's [KV API](https://developer.hashicorp.com/consul/api-docs/kv)
and [transaction API](https://developer.hashicorp.com/consul/api-docs/txn).

For a current or explicitly pinned certificate read:

1. Read the CertID metadata once to obtain selection and status.
2. Read the public version once, or use one read transaction for the public
   version and optional encrypted private key together.

The Ruby reader caches the selection and material for its lifetime. Supplying
an area's decryption key opts into fetching its encrypted private material on
the second request, even if the first requested field is public. Omit area keys
for public-only clients. The transaction uses `get-or-empty` for an optional
private key, allowing public-only certificate versions with a key-enabled client.
Additional `metadata`, `certificate` and `private_key` field calls use the cache.
Use a fresh reader for a fresh selection. UI preview and confirmation are separate
operations and deliberately recheck the metadata before publishing.

Consul supports atomic transactions with up to 64 operations and values up to
512 KiB. See [Consul transactions](https://developer.hashicorp.com/consul/api-docs/txn).
A bulk import consists of individual certificate writes, so partial success is
reported per certificate and area.

## Chains

Every leaf, intermediate and root certificate is stored separately. Importing a
bundle through the UI creates an independent entry for every certificate.
External writers publish each CA certificate with its own CertID.

A client constructs a chain only when requested. The Ruby/Puppet reader fetches
public certificate candidates for the same area in one additional recursive
read, caches them, and follows issuer/subject matches with signature verification
and a CA constraint check. It considers stored historical certificates too.
The UI uses authorized certificate candidates from its catalog and loads their
material. Neither implementation uses a stored chain or fetches AIA URLs.
Missing issuers produce a partial chain. Ambiguous cross-signed paths are not
resolved through a trust-store policy. Chain assembly is not trust, expiry,
revocation or hostname validation. Discovery is outside the two-request budget
for reading an individual certificate.

## Status and archiving

Status belongs to the CertID and applies to every version:

| Status | Intended Puppet behavior |
| --- | --- |
| `active` | Maintain the configured certificate normally. |
| `norollout` | Leave existing files unchanged and do not recreate missing files. |
| `delete` | Remove previously managed certificate and key files. |

The supplied Puppet manifests expose status as metadata but do not enforce these
behaviors yet. Setting `delete` does not physically delete Consul material.

“Archivieren” sets `archived: true`, `status: "delete"`, `archived_at` and
`archived_by` after confirmation. Archived entries are hidden from the normal
overview but remain searchable and retain all versions and keys. Imports preserve
archive state. Archived entries cannot be reactivated through the UI. There is
no UI action to reverse archiving. Status and archive changes CAS the metadata
against the index seen on the form. Filesystem entries have neither control.

## UI audit history

UI imports, activation, status changes and archiving are recorded directly in
PostgreSQL with the authenticated user, UTC timestamp, area, CertID, versions,
certificate identity and before/after metadata. No private keys, passwords or
PEM contents are included. An intent is persisted **before** the Consul write.
Its outcome becomes `succeeded` after acknowledgment or `rejected` on CAS conflict.
A connection error produces `unknown`. A process crash can leave `pending`.
The UI displays these outcomes and never presents an uncertain write as confirmed.
If persisting the intent fails, no Consul mutation is attempted.

PostgreSQL and Consul do not share a distributed transaction. After an uncertain
outcome, inspect Consul and the intent before retrying. An acknowledgment followed
by a PostgreSQL failure can leave a pending record even though Consul committed.
Audit intents retain the requested change, but automatic reconciliation is not
implemented. Export events are persisted before HTTP delivery, as before.
Back up PostgreSQL to retain UI history. Reindexing Consul does not recreate it.

Direct Puppet imports do not create UI audit events. Their immutable version
contains `client: "puppet"` and `created_at`, displayed in certificate details.
The mutable CertID metadata also carries the most recent writer and timestamp.
This is the entire machine-write provenance contract.

## Ruby writer

The helper uses only Ruby standard libraries:

```ruby
require_relative "lib/cci_writer"

writer = CciWriter.new(
  connection: ConsulConnection.new(url: ENV.fetch("CONSUL_URL")),
  prefix: ENV.fetch("CONSUL_PREFIX", "cci")
)
version = writer.save(
  area: "zone_a", certid: "portal.production",
  cert: OpenSSL::X509::Certificate.new(File.read("portal.pem")),
  key: OpenSSL::PKey.read(File.read("portal.key")),
  tags: ["Production"], client: "puppet"
)
# version is Integer 1, then 2, and so on.
```

Pass a single certificate, an optional matching key, tags and client identity.
The helper calculates the version, timestamp, envelope and transaction. It does
not take a chain. A `ConsulConnection::Conflict` requires a fresh attempt.

Runnable example:

```console
CCI_CLIENT_ID=puppet ruby examples/add_certificate.rb zone_a portal.production portal.pem portal.key
```

Writing tokens need read/write access to the area's `certids/`, `certs/` and,
when applicable, `keys/`. No other prefix is needed. Certificate-only readers
need no access to `keys/`.

## Ruby reader and Puppet

```ruby
require_relative "lib/cci_client"

reader = CciClient.new(
  url: ENV.fetch("CONSUL_URL"), token: ENV.fetch("CONSUL_TOKEN", ""),
  keys: { "zone_a" => ENV.fetch("ZONE_A_KEY") }, prefix: "cci"
)
selection = { area: "zone_a", certid: "portal.production" }
pem = reader.fetch(**selection)
key = reader.fetch(**selection, field: "private_key")
metadata = reader.fetch(**selection, field: "metadata")
# These three calls together use two HTTP requests.
pinned = reader.fetch(**selection, version: 1)
fullchain = reader.fetch(**selection, field: "chain")
```

Metadata exposes integer `version`, `certid`, `status`, fingerprints, tags,
key availability and import provenance. `chain` returns leaf PEM followed by
available issuers. An explicit version must be a positive Ruby integer.
The standalone reader returns metadata and the public certificate. Its Ruby
method accepts `include_chain: true` and `private_key: true` when needed.
The command accepts a decimal version argument:

```console
ruby examples/read_certificate.rb zone_a portal.production 1
```

See [Puppet integration](puppet.md) for `cci::certid`, integer version pinning,
ACLs and Hiera examples. Run `ruby bin/package-puppet` after editing shared Ruby
helpers. Keep the UI, writers and readers on this same contract.
