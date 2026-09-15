# Puppet integration

## Comparison and idempotence

Puppet compilers read new data directly through the Consul HTTP API. The web
application does not need to be running for these requests. The supplied `cci`
module creates native Puppet `file` resources with deterministic PEM contents
and `checksum => 'sha256'`. The agent compares the catalog's desired content
with the existing file and writes only when contents or permissions change.
It does not reissue certificates or generate a randomized PKCS#12 container
on every run.

The Ruby reader pins the active version ID for the duration of a compile.
Certificate and key therefore come from the same version even if renewal happens
concurrently. The next compile sees the new active version. A version ID can
also be pinned explicitly.

The adapter exposes `metadata` containing the version ID, certificate fingerprint
and public-key fingerprint. Native file management needs no separate API
comparison. The agent requires neither Consul credentials nor the area secret;
these are held by the compilers.

## Prepared status contract

CCI-UI can set `active`, `norollout`, or `delete` for each certificate, including
legacy certificates. This release prepares UI and Consul storage only; the
supplied `cci::certificate` manifests do **not** implement status processing.
They continue to manage configured files even when a stored status is
`norollout` or `delete`. Deploy status-aware Puppet code before relying on these
values to suspend rollout or remove files.

The intended behavior is:

| Status | Future Puppet behavior |
| --- | --- |
| `active` | Deploy and maintain the configured certificate normally. |
| `norollout` | Do not deploy or recreate missing certificate/key files; leave existing files unchanged. |
| `delete` | Remove managed certificate/key files even after removal from Hiera. |

For Consul material, `$metadata['status']` from `cci::lookup(..., 'metadata')`
exposes the lookup's status, defaulting to `active` for older entries. The status
also applies to explicitly pinned versions. Existing certificate and key reads
continue to return material without acting on that status.

Legacy status is stored separately at
`<prefix>/areas/<area>/filesystem-statuses/<sha256-of-certificate-DER>`.
Identical legacy certificates within one area share it. Missing records mean
`active`. Once the last disk copy disappears, the indexer removes its legacy
status record after a complete successful scan. Future Puppet cleanup must
account for this lifecycle; it cannot rely on that record persisting after disk
removal. See the [complete Consul schema](consul-schema.md).

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
The two copied Ruby files are generated from `lib/`; edit the originals there
and run `bin/package-puppet` again.

Set the following in the compiler process environment:

```text
CCI_CONSUL_URL=https://consul.example.internal:8501
CCI_CONSUL_PREFIX=cci/v1
CCI_ZONE_A_CONSUL_TOKEN=<ACL token for the example area zone_a>
ZONE_A_KEY=<Base64 secret; required only for private-key distribution>
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
    lookup: portal.production
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
$metadata = cci::lookup('zone_a', 'portal.production', 'metadata')
$pem = cci::lookup('zone_a', 'portal.production', 'certificate')
```

Existing NFS data stays with the legacy Puppet module. Its Hiera settings
continue to use `issuer` and `subject`, including historical tags. The application
displays these values for files without inventing new Consul lookups for legacy
data. Exact integration depends on the existing Puppet lookup code, which has
not yet been supplied.

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
`<UPPERCASE_AREA_ID>_KEY`. Consul ACLs enforce compiler access. Examples use
`zone_a`; existing deployments retain their configured IDs.
