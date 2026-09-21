# Puppet integration

## Comparison and idempotence

Puppet compilers read new data directly through the Consul HTTP API. The web
application does not need to be running for these requests. The supplied `cci`
module creates native Puppet `file` resources with deterministic PEM contents
and `checksum => 'sha256'`. The agent compares the catalog's desired content
with the existing file and writes only when contents or permissions change.
It does not reissue certificates or generate a randomized PKCS#12 container
on every run.

The Ruby reader pins the active integer version for the duration of a compile.
Certificate and key therefore come from the same version even if renewal happens
concurrently. The next compile sees the new active version. A version number can
also be pinned explicitly.

The adapter exposes `metadata` containing the integer version, certificate fingerprint
and public-key fingerprint. Native file management needs no separate API
comparison. The agent requires neither Consul credentials nor the area secret;
these are held by the compilers.

## Prepared status contract

CCI-UI can set `active`, `norollout`, or `delete` only for Consul certificates.
Filesystem certificates have no mutable status and cannot be archived. This
release prepares only the UI and Consul storage. The supplied
`cci::certificate` manifests do **not** implement status processing.
They continue to manage configured files even when a stored status is
`norollout` or `delete`. Deploy status-aware Puppet code before relying on these
values to suspend rollout or remove files.

The intended behavior is:

| Status | Future Puppet behavior |
| --- | --- |
| `active` | Deploy and maintain the configured certificate normally. |
| `norollout` | Do not deploy or recreate missing certificate/key files; leave existing files unchanged. |
| `delete` | Remove managed certificate/key files even after removal from Hiera. |

For Consul material, `$metadata['status']` from `cci::certid(..., 'metadata')`
exposes the certid's status, defaulting to `active` for older entries. The status
also applies to explicitly pinned versions. Existing certificate and key reads
continue to return material without acting on that status.

Filesystem certificates remain read-only UI catalog entries without Consul state.
“Archivieren” sets `archived: true` and `status: delete` on a Consul certid without
deleting material; it also applies to pinned versions and future renewals.
See the [complete Consul schema](consul-schema.md).

Cleanup independent of Hiera requires a future Puppet implementation to keep
an inventory of previously managed paths on each node and to discover deletion
requests outside the current Hiera configuration. Consul status metadata does
not contain target paths, and the current module does not retain this inventory.
Do not delete status records as a substitute for setting `delete`.

## Installing the module

```console
ruby bin/package-puppet
```

The complete module is available under `integrations/puppet/cci`. Deploy this
directory into your module path using your normal Puppet code distribution.
The adapter requires Ruby standard libraries and OpenSSL, not Rails gems.
The copied Ruby files are generated from `lib/`; edit the originals there
and run `bin/package-puppet` again.

Set the following in the compiler process environment:

```text
CCI_CONSUL_URL=https://consul.example.internal:8501
CCI_CONSUL_PREFIX=cci
CCI_ZONE_A_CONSUL_TOKEN=<ACL token for the example area zone_a>
CCI_AREA_KEYS={"zone_a":"<Base64 secret; required only for private-key distribution>"}
CONSUL_CA_FILE=/etc/ssl/certs/consul-ca.pem
```

Supply tokens and secrets through your secret-management system, not plaintext
Hiera or catalog parameters. Distributed private keys are marked `Sensitive`
but remain part of the catalog. `Sensitive` does not encrypt the catalog;
protect its transport, storage and access accordingly. Diffs and file backups
are disabled for private keys.

## Hiera for Consul certificates

```yaml
cci::certificates:
  portal.production:
    area: zone_a
    certid: portal.production
    path: /etc/ssl/certs/portal.pem
    key_path: /etc/ssl/private/portal.key
    include_chain: true
```

Include class `cci` in the catalog, for example with `include cci`.
Target directories must already exist. Owner and group default to `root`;
certificate files use mode `0644`, key files `0600`. Omit `key_path` when
only public material is needed.

Direct function calls:

```puppet
$metadata = cci::certid('zone_a', 'portal.production', 'metadata')
$pem = cci::certid('zone_a', 'portal.production', 'certificate')
```

Pin an integer version with `version: 2` in Hiera, or:

```puppet
$pem = cci::certid('zone_a', 'portal.production', 'certificate', 2)
```

Certificates are stored individually. `include_chain: true` builds the chain
in the client with an additional public-certificate discovery read. Intermediate
and root certificates must be published separately. Missing issuers produce a
partial chain. This is not trust-store or revocation validation.

A read uses one metadata request and one material request. Configuring an area
secret opts into fetching the encrypted private key with the public material.
Public-only clients should omit that secret. Subsequent fields use the same
cached version within the compile.

Direct Puppet writers can use the packaged `CciWriter` helper with
`client: "puppet"`. It records UTC import time without a required human actor,
using one metadata read and one atomic write. See the
[writer example](consul-schema.md#ruby-writer). The supplied manifest remains a
reader and does not automatically issue or upload certificates.

Existing NFS data stays with the legacy Puppet module. Its Hiera settings
continue to use `issuer` and `subject`, including historical tags. Hiera name
formatting preserves the original ASN.1 value bytes and escapes non-ASCII bytes
as `\xHH` (for example, UTF-8 `ü` becomes `\xC3\xBC`). This also handles
OpenSSL name values returned as `ASCII-8BIT` without lossy character replacement.
Display names are decoded separately according to their ASN.1 string type for
the UI and search index; this does not change the literal Hiera lookup values.
The application displays these values for files without inventing new Consul certids for legacy
data. Exact integration depends on the existing Puppet lookup code, which has
not yet been supplied.

## Optional host reporting through PuppetDB

The application can query an existing custom certificate fact to show host
counts and hostnames. This is separate from the `cci` deployment module: it
does not install a fact or Puppet class, and reporting does not implement the
prepared status contract above. Use the actual fact name and matching SHA-256
or SHA-1 algorithm in your deployment. Examples use the neutral name
`certificates`; see [PuppetDB host inventory](puppetdb.md) for supported formats,
configuration and query scope.

## Verification

`test/puppet_idempotence.rb` creates synthetic certificates under a random Consul
test prefix and uses temporary target files. With local Puppet 8 and an isolated
Consul instance, run:

```console
CCI_CONSUL_URL=http://127.0.0.1:8500 ruby test/puppet_idempotence.rb
```

Expected exit codes from the Puppet runs are `2` (initial change), `0`
(unchanged) and `2` (renewal). The test also checks that the certificate file's
modification time remains unchanged on the second run. The test prefix is
removed afterward. Do not use a production Consul instance for this test.

## Configurable areas

`area` is an ID from the application's area configuration. The module has no
fixed area list. It accepts the same ID format: up to 48 lowercase letters,
digits or underscores, starting with a letter. Each ID uses
`CCI_<UPPERCASE_AREA_ID>_CONSUL_TOKEN` and, for private-key distribution,
`CCI_AREA_KEYS` (or the per-area `<UPPERCASE_AREA_ID>_KEY` fallback). Consul
ACLs enforce compiler access. Examples use
`zone_a`; existing deployments retain their configured IDs.
