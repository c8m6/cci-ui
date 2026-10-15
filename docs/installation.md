# Installation and operations

## Local development on a VM

Install Docker Engine, Docker Compose 2.24+, Ruby and the Linux `acl` tools. From the repository:

```console
ruby bin/setup-local
setfacl -m u:10001:r config.yml
docker compose -f compose.yml up --build -d --wait
```

Open http://localhost:3000 and select a local synthetic identity. The helper
creates protected `config.yml` with independent area keys. Keep this file;
regenerating keys makes existing encrypted material unreadable. Existing ENV
installations require manual migration before starting the new code. Copy their
exact keys into YAML; `setup-local` is only for a new installation.

Compose starts PostgreSQL, Consul, one migration job, web and indexer. The
indexer defaults to 60 seconds between passes. Local authentication is prohibited
in production. Application settings come exclusively from YAML; see the
[complete configuration reference](configuration.md) and
[config.example.yml](../config.example.yml). Restart services after edits:

```console
docker compose -f compose.yml up -d --force-recreate migrate web indexer
```

The application image excludes local configuration, secrets, `data/` and Git.
Release metadata continues to come from the release build.

## Configuring areas

Define stable IDs under `areas`, each with a name and the existing Base64
32-byte encryption key. Optionally add `filesystem.legacy_path` and Consul
connection overrides. Read-only legacy indexing does not migrate material.
Never rename IDs merely to change labels. Roles, stored references and encryption
contexts use the IDs. Existing records remain stored when an area is removed.

```yaml
areas:
  global:
    name: Global
    encryption_key:
      file: /run/secrets/global-key
    filesystem:
      legacy_path: /legacy/global
    consul:
      token:
        file: /run/secrets/global-token
```

Mount the same paths and contents in all consumers. Web requires read/write
legacy access only for the existing confirmed filesystem deletion action;
indexer uses read-only access. `LEGACY_PATH` in production Compose is the host
parent mounted at `/legacy`. Omit filesystem mappings and mounts when unused.
For inventories in separate host directories, add each bind mount explicitly.
Area encryption is independent of the Consul ACL token. Multiple areas can
inherit one cluster or select independent clusters; see
[inheritance and ACLs](configuration.md#area-identity-and-multiple-consul-clusters).

## Tests

Use the disposable services and synthetic configuration, never production data:

```console
docker build -t cci-ui:ci .
docker compose -f compose.ci.yml up -d --wait db consul
docker compose -f compose.ci.yml run --rm app ruby bin/rails db:prepare test
docker compose -f compose.ci.yml down --volumes
```

Direct Rails tests use `CCI_CONFIG_FILE=test/config.yml` (local PostgreSQL and
Consul). The container tests use `test/container.yml`. Test helpers create
synthetic certificates, an isolated legacy directory and a random Consul prefix.
See [required security checks](container-publishing.md#security-validation).

## Keycloak

Create an OIDC client with Authorization Code flow and PKCE. Configure the exact
redirect URI, issuer, client ID and client secret under `authentication.oidc`.
Production issuer and redirect URLs require HTTPS. Publish the needed role
claims for the client. Sessions last one hour; changes apply on a new login.

CCI-UI reads `groups`, `realm_access.roles` and client roles under
`resource_access.<client_id>.roles`. Other clients' roles are ignored. Direct
CCI role names work without a mapping. An optional native YAML `role_map`
translates incoming names once; unknown effective roles grant no access.
Unknown target roles/areas in the map stop startup.

```yaml
authentication:
  mode: oidc
  oidc:
    issuer: https://auth.example.test/realms/cci
    client_id: cci-ui
    client_secret:
      file: /run/secrets/oidc-client-secret
    redirect_uri: https://cci.example.test/auth/keycloak/callback
    display_name_claim: preferred_username
    role_map:
      /cci/editors: global_writer
      /cci/requesters: [global_reader, global_csr]
      /cci/auditors: [global_auditor, secure_auditor]
```

Each role uses `<area>_reader`, `_writer`, `_key_exporter`, `_csr` or `_auditor`.
Writer and Key Exporter imply certificate read access; CSR and Auditor remain
independent. Key Exporter alone permits private-key export. CSR grants only
its own lifecycle, including publication of matching certificates. The role menu
shows actual assigned CCI roles without changing permissions.

The OIDC subject stays the stable audit identity. `display_name_claim` selects
`preferred_username` (default), `name` or `email`; a missing value falls back
to the UID. `server.log_level: debug` logs interpreted authorization diagnostics
without token bodies. A login with no effective CCI role clears the session and
returns a localized permission message. For local SSO testing, change YAML to
OIDC mode and supply the same settings, then restart.

## Production deployment

Use an immutable image tag or digest, PostgreSQL, Consul and an HTTPS reverse
proxy. Local identities are unavailable in production. Prepare protected
`config.yml`, `secrets/` and TLS files using [config.example.yml](../config.example.yml).
Copy existing encryption/session secrets unchanged. Ensure UID 10001 can read
files, while preventing access by unauthorized users.

The production template mounts YAML at `/etc/cci/config.yml` read-only. It also
mounts `secrets/` and `tls/` read-only into web, indexer and migrate. Change host
paths through the infrastructure variables `CCI_CONFIG_FILE`, `CCI_SECRETS_PATH`,
`CCI_TLS_PATH` and `LEGACY_PATH`, or edit the deployment manifest. The bundled
PostgreSQL password must match `database.password` in YAML.

```console
CCI_IMAGE=c8m6/cci-ui:<release-tag> POSTGRES_PASSWORD='<database-password>' LEGACY_PATH=/srv/cci/legacy docker compose -f compose.production.yml up -d --no-build --wait
```

For external PostgreSQL and Consul, use [compose.full.yml](../compose.full.yml)
and its [deployment notes](compose-full.md). Do not point local tests at those
systems. Keep one indexer active and run the migration job successfully before
starting replicas. Database setup is never part of normal web startup.

## Backup and recovery

Back up PostgreSQL (audit history, CSR secrets, issued certificate history and
publication intents), Consul snapshots, legacy material and the protected YAML/
secret files. Store backups and encryption keys through separate protected
channels. Backups of data encrypted with old keys require those old keys.
Reindexing does not restore audit records or CSR state. Restore these components
as one coordinated version before resuming writers. Test restores independently.

## Troubleshooting

A YAML configuration error stops boot. Check the referenced file exists inside
every container and is readable by UID 10001. An invalid key is never silently
replaced. Use `docker compose logs web indexer migrate`, and keep diagnostic
output protected. Do not enable raw HTTP logging. Missing source mounts or TLS
failures preserve previous inventory data and appear in structured logs.

The dashboard and host pages use local projections; timestamps describe recorded
checks, not live readiness or current host deployments. See [UI behavior](technik.md)
and [PuppetDB observations](puppetdb.md). See [filesystem recovery](legacy-deletion.md)
for confirmed deletion and fail-safe automatic reconciliation.

## Health checks

| Endpoint | Purpose | Dependencies |
| --- | --- | --- |
| `/up` | Process liveness | Rails only |
| `/ready` | Load-balancer readiness | PostgreSQL connection, writable primary, current migrations |
| `/health` | Full dependency diagnostics | PostgreSQL, Consul, configured legacy directories, optional PuppetDB and OIDC discovery |

`/up` and `/ready` remain anonymous. `/health` requires
`Authorization: Bearer <token>`, with the expected high-entropy token supplied as
`server.health_token` in the web deployment secret. Configure your monitoring client
to send this header and make sure every reverse proxy forwards it. An absent
configured token makes `/health` unavailable (HTTP 503); an absent or invalid
request token receives HTTP 401. Neither case runs dependency checks.

Readiness and diagnostics return HTTP 200 with `{"status":"ok"}` or HTTP 503
with `{"status":"unavailable"}`. `/health` shares each check result within a web
process for up to 10 seconds, starting a refresh after five seconds. Only one
refresh runs per process; concurrent requests receive the last result while it
is still valid, or HTTP 503 if none is valid. All diagnostic responses retain
`Cache-Control: no-store`; proxies and clients must not cache them.
`server.show_error_details: true` exposes diagnostic details. Leave it disabled in production.

Compose uses `/ready`. Use `/up` for orchestrator liveness and `/ready` for
routing. Do not restart replicas because a shared dependency is unavailable.
Normal page requests no longer run global dependency probes. Catalog and audit
pages can remain available during a Consul outage. Operations that need an
unavailable service still fail, including new OIDC logins when Keycloak is down.

Readiness performs no persistent writes. It checks PostgreSQL recovery and
transaction read-only state and rejects pending migrations. It does not prove
table write privileges, available disk space, indexer freshness or external
write access. Database connection and pool checkout timeouts are three seconds.
Probe statements have a two-second timeout and a one-second lock timeout.
These limits apply individually, not as one total probe deadline.

Full diagnostics verify external read access. An accessible empty legacy
directory is valid and cannot be distinguished from an empty mount point.

## Deploying multiple web replicas

Run `ruby bin/rails db:prepare` exactly once as a deployment job using the
new application image and the primary database endpoint. Require a successful
exit before starting the new web replicas and indexer. A failed job must stop
the rollout. `bin/start` logs startup dependency diagnostics before starting Puma and never migrates the database.

The Compose templates enforce this ordering through the one-shot `migrate`
service and `service_completed_successfully`. For a deployment with external
clusters, implement the equivalent job in your orchestrator. The production
Compose file is a single-host example, not a multi-host HA orchestrator.
Recreate the migration job for every release, even if the previous job succeeded.
For a Compose release, run:

```bash
docker compose -f compose.production.yml run --rm --no-deps migrate && \\
  docker compose -f compose.production.yml up -d --no-deps web indexer
```

Use the same immutable image for all three services. Build or pull it before
running the job. Keep one indexer active. Share `server.secret_key_base`, area keys,
OIDC settings and role mappings across replicas. Legacy operations require
the same mounted inventory on each replica.

During rolling deployments, migrations must remain compatible with the old
replicas. Use additive migrations first and defer incompatible removals until
the old version has stopped. Extra migration versions from a newer replica
do not by themselves make an older replica unready. Test actual database,
Consul and load-balancer failover in your environment before production use.

## Upgrade compatibility

The standalone Ruby reader exposes `CciClient#read_certificate`, replacing the
former `fetch` method. Routes use English paths such as `/login`, `/local-login`,
`/logout`, `/locale`, `/certificates`, `/imports/preview` and `/audit_events`,
independently of the selected interface language. Update older external callers
and bookmarks that still use the former method or German paths.

## Manual acceptance checks

Use synthetic data in a separate development deployment. Copy existing area
keys unchanged only when migrating an existing dataset; never connect disposable
tests to production databases or certificate inventories.

1. As an area's CSR user, create a synthetic CSR and delete it after confirming.
   Check that it disappears, its former direct URLs return 404, and the area's
   auditor sees **CSR deleted** / **CSR gelöscht**. Create another CSR, upload a
   matching synthetic certificate, and verify that deletion is no longer offered.
2. Import into exactly one authorized area. Repeat independently in another
   area if needed; the first area's data must remain unchanged. A multi-area
   request must be refused.
3. Restart after YAML edits. Confirm that a wrong type, unknown key, unknown role
   reference or missing secret file prevents startup without printing values.
   In a separate two-Consul test deployment, use different area URLs/prefixes and
   verify that writes and reads stay in the selected cluster.
