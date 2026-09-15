# CCI-UI

**Controlled classified item** — certificate management with configurable permission
areas, built with Ruby on Rails, Hotwire, PostgreSQL and HashiCorp Consul.

Search legacy files and new certificates together, manage certificate versions
and Puppet status, and export PEM, DER, PKCS#12/PFX or JKS. The application interface is in German.

## Quick start

```console
ruby bin/setup-local
docker compose up --build -d
```

Open [http://localhost:3000](http://localhost:3000) and select a local test identity.
Keycloak is optional in explicit local mode.

The example configuration uses **Zone A** and **Zone B**. Local certificates
under `data/` are mounted read-only and assigned to Zone A through `legacy_area`
in [config/areas.yml](config/areas.yml). New uploads are stored only in Consul.
The indexer refreshes search metadata every 60 seconds.

Area IDs and display names are configurable. Roles, local test identities and
selection fields are generated from the configuration; adding an area requires
no code changes. See [Configuring areas](docs/installation.md#configuring-areas).

## Screenshots

These screenshots show the actual application using **synthetic demonstration
data only**: example domains, generated certificates and demo identities.
They contain no real certificate, organization or user information. The screenshots
predate the separate “Puppet-Status” column and status editor.

### Certificate overview

Search, validity filters, source information and Puppet lookups in the light theme.

![Certificate overview with synthetic certificates in Zone A and Zone B](docs/screenshots/overview.png)

### Certificate details

Certificate metadata, linked chain certificates, version information and Hiera
configuration in the dark theme.

![Certificate details in the dark theme using a generated example certificate](docs/screenshots/details.png)

### Audit logs

Area-restricted audit access with timestamps, users, certificate identities and
export options. This example filters the log to certificate exports.

![Audit log showing synthetic certificate exports by a demo user](docs/screenshots/audit.png)

## Permissions and formats

Readers can search and view details but cannot export. Writers can import,
manage versions and export certificates. Exporting private keys additionally
requires `<area_id>_key_exporter` in the same area.

`<area_id>_auditor` grants access to that area's audit logs without granting
certificate export rights. Logs record changes and exports with time, user and
persistent certificate metadata, including exported chain certificates.

PEM, DER, PKCS#12/PFX and JKS are supported, including bulk and chain exports
where applicable. JKS currently requires matching store and key passwords.
PKCS#12 supports AES/PBES2 and 3DES; legacy RC2 is not supported.

## Overwrite confirmation and Puppet status

Imports into an existing area/lookup require explicit confirmation in the preview.
The server checks that the lookup has not changed since preview; older versions
remain available after renewal. Uploads containing a certificate already on disk
are rejected by DER fingerprint, regardless of lookup or target area. The disk
inventory is checked both before preview and before saving.

Writers can set `active`, `norollout`, or `delete` in certificate details for
both Consul and legacy certificates. The overview displays “Puppet-Status” and
provides a matching filter, independent of “Gültigkeit”. Status changes are
audited. Consul stores lookup status and separate legacy metadata; local files
remain unchanged. Renewals preserve lookup status. Once the last legacy disk
copy is removed, the indexer removes its Consul status record and catalog entry
after a successful scan. Audit history remains available.

**Puppet execution is deferred:** this release prepares UI and Consul only.
The supplied Puppet manifests do not yet enforce the three statuses. See the
[status contract and rollout requirements](docs/puppet.md#prepared-status-contract).

## Documentation

- [Installation and operations](docs/installation.md)
- [Technical architecture and data storage](docs/technik.md)
- [Consul schema, client provenance and Ruby import examples](docs/consul-schema.md)
- [GitHub Actions builds and Docker Hub publishing](docs/container-publishing.md)
- [Puppet integration and idempotence](docs/puppet.md)
- [Implemented change requests](docs/aenderungen.md)

## Tests

```console
docker compose run --rm -e RAILS_ENV=test web ruby bin/rails db:prepare test
```

Tests generate their own certificates and use a separate PostgreSQL database
and Consul namespace. Private keys from `data/` are not copied into test fixtures
or Docker images. The legacy application under `quelle/`, local certificate
files, runtime data and secrets are excluded from version control.
