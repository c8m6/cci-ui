# CCI-UI

**Controlled classified item** — certificate management with configurable permission
areas, built with Ruby on Rails, Hotwire, PostgreSQL and HashiCorp Consul.

Search legacy files and new certificates together, manage certificate versions,
and export PEM, DER, PKCS#12/PFX or JKS. The application interface is in German.

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
They contain no real certificate, organization or user information.

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

## Documentation

- [Installation and operations](docs/installation.md)
- [Technical architecture and data storage](docs/technik.md)
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
