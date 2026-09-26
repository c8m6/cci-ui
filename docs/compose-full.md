# Complete inline Compose configuration

[compose.full.yml](../compose.full.yml) is a production template for existing
PostgreSQL, Consul, Keycloak and PuppetDB services. It contains all application
feature settings directly in YAML, without `env_file` or variable substitutions.
The existing development and production templates are unchanged.

CA inventory and PuppetDB inventory are enabled. CSR defaults, role mappings,
area encryption keys, legacy directories, Consul TLS, PostgreSQL TLS and
PuppetDB mutual TLS are included. Error details and the optional PuppetDB token
are present but disabled/empty by default. CSR access is granted by the
`<area>_csr` role, not by a separate feature switch.

## Configure and start

1. Build the image with `docker build -t cci-ui:local .`, or change `x-image` to
   your published immutable image tag.
2. Copy the template outside the repository, for example to
   `/srv/cci/compose.yml`, and edit that copy. Keep real credentials out of Git
   and Docker build contexts. Restrict access to the deployment file.
3. Replace every `REPLACE_*` value, example hostname, role mapping and mount
   source. URL-encode the PostgreSQL password. Escape literal dollar signs in
   Compose values as `$$`. Use existing area keys when data already exists.
4. Supply the mounted CA/client files and legacy directories. The image runs as
   UID 10001, which needs read access to TLS files and inventory, and write access
   to legacy files for web deletion. Missing mount sources fail rather than
   silently creating empty directories.
5. Configure an HTTPS proxy or load balancer for `cci.example.test`. The example
   publishes only `127.0.0.1:3000`, suitable for a proxy on the Docker host.
   Adjust the binding for a remote load balancer.

For a new deployment:

```bash
docker compose -f /srv/cci/compose.yml config --quiet
docker compose -f /srv/cci/compose.yml up -d --wait
```

No environment file or exported application variables are needed. The template
uses literal values only. Compose may still discover its own default `.env`;
use `--env-file /dev/null` if you also want to disable that discovery.

For later releases, make migration success a prerequisite for updating replicas:

```bash
docker compose -f /srv/cci/compose.yml run --rm --no-deps migrate &&
  docker compose -f /srv/cci/compose.yml up -d --no-deps --wait web indexer
```

Prepare the selected image before running these commands. Use `/ready` for
load-balancer readiness, `/up` for process liveness and `/health` for dependency
diagnostics. See [HA deployment](installation.md#deploying-multiple-web-replicas).

## Settings by service

| Service | Configuration |
| --- | --- |
| Web | Rails boot, database, Consul write token, inventory, PuppetDB, encryption keys, UI roles, OIDC display name, diagnostics, port and CSR defaults |
| Indexer | Rails boot, database, Consul read token, inventory, PuppetDB and indexing interval |
| Migration job | Rails boot and database only |

The indexer deliberately receives no `CCI_AREA_KEYS`, individual area keys,
`CSR_DEFAULT_*`, `OIDC_ROLE_MAP`, `OIDC_DISPLAY_NAME_CLAIM`,
`CCI_SHOW_ERROR_DETAILS` or `PORT`.
It reads public certificate material and does not decrypt stored private keys.
Its Consul token needs read access to all configured certid and certificate
prefixes, including the transaction reads used by CA discovery. PostgreSQL
access must allow catalog updates and expired import-draft cleanup.

The indexer and migration job currently load the full production Rails
application. Consequently `SECRET_KEY_BASE`, `ALLOWED_HOSTS`, `AUTH_MODE` and
the four OIDC connection settings are required for boot even though these
processes do not serve requests. The shared boot anchor documents this
dependency explicitly. `RAILS_MAX_THREADS` also controls the database pool.
`LOG_LEVEL` is shared so web, indexer and migration output use the same threshold.

Legacy storage is mounted read/write for web and read-only for the indexer.
TLS mounts are read-only. Web receives PuppetDB connection settings because
`/health` probes PuppetDB, although normal pages use cached host mappings.
Keep one indexer active across deployment hosts. This file supplies application
services, not HA clusters for the external dependencies.

For system-trusted Consul/PuppetDB certificates, empty the corresponding
`*_CA_FILE` value and remove its mount if unused. For PostgreSQL, retain
`sslmode=verify-full` and configure an appropriate trust source. For PuppetDB
without mutual TLS, empty both client certificate/key settings together.
Keep `PUPPETDB_TOKEN` empty unless your endpoint requires it. Set
`CCI_LEGACY_PATHS` to `{}` and remove legacy mounts if no disk inventory exists.
