# Installing CCI-UI

For prebuilt images and CI setup, see [GitHub Actions and Docker Hub](container-publishing.md).
For direct imports and client identity, see [Consul schema and Ruby examples](consul-schema.md).

## Local development on a VM

Requirements: Docker Engine with Compose 2.24 or newer (optional `env_file` support), an available local port
3000, approximately 2 GiB of available RAM for initial evaluation, and internet
access when building images. The local secret setup helper requires Ruby;
alternatively, create the environment variables using `.env.example` as a guide.

From the project directory:

```console
ruby bin/setup-local
docker compose up --build -d
docker compose ps
```

`bin/setup-local` optionally creates the area/path JSON variables and random,
separate secrets for the configured areas in
`.env` with permissions `0600`. It does not overwrite an existing file. The file
is excluded from Git and the Docker build context. Preserve its secrets across
container restarts so existing private keys remain readable. The application
also starts with variables supplied directly by the shell or your orchestrator;
no `.env` or application configuration file is required. For a new installation,
`ruby bin/setup-local --stdout` emits shell-safe `export` commands without writing
a file. Do not regenerate keys when migrating an existing installation.

Open `http://localhost:3000`. For a remote VM, expose the local port through an
SSH tunnel. The development service binds only to `127.0.0.1`; the databases
do not publish host ports.

Compose starts Rails, a Ruby indexer, PostgreSQL and a persistent single-server
Consul instance. Application startup prepares the database and runs migrations.
`data/` is mounted read-only at `/legacy`. The development Compose defaults set
`CCI_AREAS` to the two example zones and `CCI_LEGACY_PATHS` to `{"zone_a":"/legacy"}`.
The indexer runs every 60 seconds, so a newly connected collection may initially
appear empty. Neither `quelle/` nor `data/` is copied into the application image.

Local mode provides Reader, Writer, Writer with Key Exporter and Auditor
identities for each configured area, plus combined identities. This mode is
for testing; the local Consul/PostgreSQL settings are not intended for network
exposure.

Inspect logs and stop services:

```console
docker compose logs --tail 100 web indexer
docker compose stop
```

`stop` preserves containers and volumes. `down` removes containers but preserves
named data volumes by default. `down -v` deletes volumes and is not part of the
normal restart procedure.

After code changes:

```console
ruby bin/package-puppet
docker compose up --build -d
```

Containers use the built application code, not a mounted working directory.

## Configuring areas

All deployment-specific application settings come from environment variables.
No area YAML file or configuration mount is used. Set the same values in web
and indexer; the Compose files forward the JSON maps to both services.

```bash
export CCI_AREAS='{"zone_a":"Zone A","zone_b":"Zone B"}'
export CCI_LEGACY_PATHS='{"zone_a":"/legacy/zone_a","zone_b":"/legacy/zone_b"}'
export CCI_AREA_KEYS='{"zone_a":"<existing Base64 key>","zone_b":"<existing Base64 key>"}'
```

These examples use JSON objects inside shell strings. `CCI_AREAS` is required
by the application and maps stable IDs to display names. IDs start with a
lowercase letter, contain only lowercase letters, digits and underscores, and
have at most 48 characters. Roles and local test identities are generated from
these IDs. `CCI_LEGACY_PATHS` maps any subset of the IDs to absolute paths inside
the containers; the application default is `{}`, meaning no local inventory.
With a custom area list in development Compose, also set `CCI_LEGACY_PATHS`
explicitly because the development template defaults to the example Zone A.

For a shared host parent such as `/mnt/certificates`, set the production Compose
variable `LEGACY_PATH=/mnt/certificates`. Its read-only `/legacy` mount makes
`/mnt/certificates/zone_a` available as `/legacy/zone_a`, and likewise for Zone B.
`LEGACY_PATH` is only the Compose host-mount setting; the application selects
its roots from `CCI_LEGACY_PATHS`.

For host directories under different parents, add explicit read-only bind
mounts to both services through your container orchestrator or a Compose
override, for example:

```yaml
services:
  web:
    volumes:
      - /mnt/zone-a-certificates:/legacy/zone_a:ro
      - /srv/zone-b-certificates:/legacy/zone_b:ro
  indexer:
    volumes:
      - /mnt/zone-a-certificates:/legacy/zone_a:ro
      - /srv/zone-b-certificates:/legacy/zone_b:ro
```

Mount declarations are container infrastructure; application settings are still
supplied through environment variables. Both processes must see identical paths
and contents. An area omitted from `CCI_LEGACY_PATHS` remains available for Consul
certificates. Map one path to multiple areas only when intentionally granting
those areas access to the same inventory; status and audit ownership stay separate.

`CCI_AREA_KEYS` maps area IDs to 32-byte keys encoded as Base64. The map lets
Compose forward arbitrary area keys from the shell without editing its service
definitions. Existing `<UPPERCASE_AREA_ID>_KEY` variables remain supported when
injected into the process; map entries take precedence. Never change key bytes
while migrating configuration, or existing private-key envelopes will no longer
decrypt. Public-only operations do not require area keys.

The Compose `env_file` is optional: `.env` for development and `.env.production`
for production. `CCI_ENV_FILE` selects another optional file. When using a file
for Compose substitutions, also pass it with `--env-file`. When supplying all
variables through the shell or orchestrator, omit the file entirely.

The process caches area/path configuration at startup. Recreate web and indexer
after changing the environment. For production with exported variables:

```console
docker compose -f compose.production.yml up -d --force-recreate web indexer
```

See the [environment reference](environment.md) for all supported variables,
a `docker run` example without configuration files, and migration instructions.
No SQL or Consul schema migration is required for this configuration change.
Preserve area IDs: they determine Consul paths, encryption, roles and audit ownership.
Removed local mappings block material reads and lose their catalog rows at the
next scan, while unscanned Consul status records and audit history remain intact.

## Tests

```console
docker compose run --rm -e RAILS_ENV=test web ruby bin/rails db:prepare test
```

Tests use `certui_test`, a separate Consul test prefix and an independent
two-zone configuration. They do not change the sample certificates.
The separate [Puppet idempotence test](puppet.md#verification) requires Puppet 8
on the test host and a reachable, isolated Consul test server.

## Keycloak

Create a confidential OIDC client for CCI-UI in the desired realm:

| Setting | Value |
| --- | --- |
| Standard Flow | Enabled |
| Client Authentication | Enabled |
| Local redirect URI | `http://localhost:3000/auth/keycloak/callback` |
| Production redirect URI | `https://cci.example.internal/auth/keycloak/callback` |
| Group/role claims | Available in the ID token or UserInfo |

Application roles follow the configured area IDs. For the example area `zone_a`:

```text
zone_a_reader
zone_a_writer
zone_a_key_exporter
zone_a_auditor
```

Key Exporter additionally requires Writer in the same area. Independent Auditor
roles allow reading audit logs within their area and grant no certificate or
export permissions. Assign the Auditor roles of all desired areas for a combined
view. Local Auditor identities land directly at `/auditlogs` after login.
Readers cannot export. Without assigned roles, the certificate list is empty.
Existing group names can be translated through JSON in `OIDC_ROLE_MAP`:

```json
{"/cci/zone_a-editors":"zone_a_writer","/cci/zone_a-key-export":"zone_a_key_exporter","/cci/auditors":["zone_a_auditor","zone_b_auditor"]}
```

For a local SSO test, set `AUTH_MODE=oidc`, `OIDC_ISSUER`, `OIDC_CLIENT_ID`,
`OIDC_CLIENT_SECRET` and `OIDC_REDIRECT_URI` in `.env`, then recreate the containers.
`OIDC_ISSUER` is the realm URL, for example
`https://keycloak.example.internal/realms/internal`.

## Production deployment

The separate `compose.production.yml` runs Rails and PostgreSQL behind an HTTPS
reverse proxy. It uses a persistent Consul instance operated by your team.
For a single Consul server on the same VM, configure its data directory,
snapshot procedure, ACLs and TLS beforehand. Ensure it is reachable from the
application containers.

Supply these variables through your deployment environment or, optionally,
a protected `.env.production` file excluded from Git and images. Preserve existing
area IDs and key bytes when migrating:

```dotenv
POSTGRES_PASSWORD=<strong database password>
DATABASE_URL=postgresql://cci:<URL-encoded password>@db/cci
SECRET_KEY_BASE=<random secret of at least 64 bytes>
ALLOWED_HOSTS=cci.example.internal
CONSUL_URL=https://consul.example.internal:8501
CONSUL_TOKEN=<application token>
CONSUL_PREFIX=cci/v1
CCI_AREAS='{"zone_a":"Zone A","zone_b":"Zone B"}'
CCI_LEGACY_PATHS='{"zone_a":"/legacy/zone_a","zone_b":"/legacy/zone_b"}'
CCI_AREA_KEYS='{"zone_a":"<32 bytes, Base64>","zone_b":"<another 32 bytes, Base64>"}'
OIDC_ISSUER=https://keycloak.example.internal/realms/internal
OIDC_CLIENT_ID=cci-ui
OIDC_CLIENT_SECRET=<Keycloak client secret>
OIDC_REDIRECT_URI=https://cci.example.internal/auth/keycloak/callback
LEGACY_PATH=/mnt/certificates
```

Generate and supply secrets using your secret-management system. The example
uses environment variables; when using Docker secret files, load their contents
into these variables before starting the application. There is currently no
built-in secret `_FILE` option. For a private Consul CA, mount the CA file in
web and indexer containers and set `CONSUL_CA_FILE` to its container path.

The container runs as UID 10001. This UID needs read access to the NFS legacy
collection, including key files if their export is permitted. Keep the mount
read-only (`:ro`); do not grant CCI-UI write access on the NFS server.

The application token needs read/write access to `cci/v1/`. Puppet receives
separate area tokens. Example read policy for a compiler that must distribute
certificates and keys from area `zone_a`:

```hcl
key_prefix "cci/v1/areas/zone_a/lookups/" {
  policy = "read"
}
key_prefix "cci/v1/areas/zone_a/versions/" {
  policy = "read"
}
key_prefix "cci/v1/areas/zone_a/private-keys/" {
  policy = "read"
}
```

Omit the final block if private keys are not needed. Each additional area needs
its own corresponding policy. Do not place management tokens on compilers.

Start services:

```console
docker compose -f compose.production.yml up --build -d
# If using an optional env file, add: --env-file .env.production
```

The reverse proxy forwards HTTPS to `127.0.0.1:3000`, preserves the original Host,
sets `X-Forwarded-Proto: https`, and limits request bodies, for example to 25 MiB.
The application allows at most 20 MiB per import. Production enforces HTTPS and
secure cookies and rejects `AUTH_MODE=local`.

Production settings are prepared but have not been validated against your
actual Keycloak/Consul infrastructure because its configuration is unavailable.

## Backup and recovery

Back up PostgreSQL, Consul snapshots, area secrets, configuration and the existing
NFS collection together. Search metadata is reconstructible; audit history and
pending previews are not fully recoverable without a database backup. Test
restoration on an isolated VM. Restore Consul using the same prefix and original
area secrets.

Do not replace existing area secrets with newly generated ones. A key-rotation
interface is not implemented. The SSO session secret, `SECRET_KEY_BASE`, can be
rotated independently; doing so invalidates existing login sessions.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Search remains empty | Indexer logs, `CCI_LEGACY_PATHS` and container mounts, file permissions, roles and Consul connectivity |
| Startup rejects area configuration | `CCI_AREAS` JSON, valid IDs/display names, and absolute `CCI_LEGACY_PATHS` |
| Upload with a private key fails | Correct Base64 encoding and exactly 32 decoded bytes in the area's secret |
| Reader sees no export action | Expected; Writer is required, plus Key Exporter for private keys |
| Consul returns HTTP 403 | Token and ACL prefix; do not copy secret values into tickets |
| SSO fails | Issuer, callback URI, client secret and claim mapping |
| JKS import fails | Use matching store and key passwords |
| Old PFX is rejected | Use AES/PBES2 or 3DES; RC2 is unsupported |

## Upgrading for certificate status

Deploy the updated image for both web and indexer. Run `ruby bin/rails db:prepare`
(or allow `bin/start` to run it) to add the indexed, constrained
`certificates.rollout_status` column. Existing records default to `active`;
the indexer then rebuilds the values from Consul. Consul needs no table migration.
The historical audit migration IDs are retained and fresh databases create
`store_event_id` directly; fully migrated installations keep their existing
column and audit history.

Give the UI read/write access to each configured area's
`<prefix>/areas/<area>/filesystem-statuses/` path, in addition to the existing
lookup/version and event permissions. This applies even though the legacy mount
remains read-only. The indexer also needs read/write access to
`filesystem-statuses/` in every area with a configured local inventory to remove
status keys after its last disk copy disappears (and read access in other areas).
For example, add this to the UI and legacy-area indexer token policies:

```hcl
key_prefix "cci/v1/areas/zone_a/filesystem-statuses/" {
  policy = "write"
}
```

Retain this metadata in Consul snapshots. A full indexing pass after deployment
can be triggered with `ruby bin/rails runner 'CatalogIndexer.run'`. Users should
start new import previews after deployment; earlier drafts lack the destination
indexes now required by the overwrite protection.

Setting a status only updates metadata in this release. The Puppet module does
not yet enforce `norollout` or `delete`; see [Puppet integration](puppet.md#prepared-status-contract)
before relying on these values operationally.

## Legacy inventory consistency

The indexer removes orphaned legacy status keys after a complete successful scan,
normally within the 60-second indexing interval. It scans and cleans each area
independently. Audit history remains available. An unavailable or unreadable
inventory aborts cleanup for that area; other areas and Consul indexing continue.
An accessible empty inventory removes all legacy status keys in its area, so
verify the NFS/disk mount before running the indexer against a changed mount configuration.

UI imports scan all configured disk inventories before preview and again before
saving.
Identical certificate DER already on disk rejects the entire upload, regardless
of lookup or destination area. A new certificate with different DER is allowed.
Every configured root must be readable. An unavailable root in any area blocks
uploads because the global duplicate check cannot be completed. Deployments
without legacy files can set `CCI_LEGACY_PATHS='{}'`. Every listed path must
refer to a readable directory inside both containers. Errors in inventory reads or certificate parsing block uploads
until corrected. No new database migration or Consul schema version is needed
for these checks.
