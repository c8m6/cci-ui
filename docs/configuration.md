# YAML configuration

CCI-UI reads one YAML file at process startup. Set `CCI_CONFIG_FILE` to its
absolute path; the default is `config.yml` in the application directory.
Web, indexer, migration tasks, standalone Ruby examples and the bundled Puppet
client use the same loader. Restart every consumer after changes. There are no
dynamic reloads, application ENV overrides or legacy fallbacks.

Use [config.example.yml](../config.example.yml) as the complete parameter
reference example. It includes two independent Consul clusters and secret-file
references. It is a deployment template: replace its endpoints, paths and secrets.
For a new disposable local setup, `ruby bin/setup-local` creates `config.yml`
with mode `0600` and independent random area keys, preserving an existing file.
`--stdout` emits YAML instead. Do not regenerate keys for existing stored data.

The loader uses safe YAML without Ruby object tags, aliases, ERB or environment
interpolation. Unknown keys, duplicate keys, invalid types, invalid area/role
references, unsafe limits, missing required values and unreadable referenced
files reject startup. Errors omit configured values and YAML source snippets.
A Boolean is `true` or `false`, never a quoted string. Integers are unquoted.
Empty optional sections inherit defaults; explicit null values are rejected.

## Parameter reference

`version: 1`, a nonempty `areas` map and database `name`, `username` and
`password` are required. Each area requires `name` and `encryption_key`.
Other sections may be omitted unless enabled or required by production mode.
All parameters below are optional unless marked required.

| Path | Type | Default or requirement |
| --- | --- | --- |
| `version` | integer | Required, exactly `1` |
| `server.host` | string | `localhost`; HTTP Host used by the local readiness probe; explicit value required in production |
| `server.port` | integer | `3000`, positive; Puma port |
| `server.allowed_hosts` | list of strings | `[localhost, 127.0.0.1]`; nonempty, explicit production list required |
| `server.secret_key_base` | secret | Development-only fallback; required in production, at least 64 characters |
| `server.show_error_details` | boolean | `false`; reveals exception details to visitors when enabled |
| `server.log_level` | string | `info`; `debug`, `info`, `warn`, `error`, `fatal` |
| `server.threads` | integer | `5`, positive; Puma threads and database pool size |
| `server.health_token` | secret | Empty; `/health` unavailable without a token |
| `database.host` | string | `db` |
| `database.port` | integer | `5432`, positive |
| `database.name` | string | Required; select an isolated database for tests |
| `database.username` | string | Required |
| `database.password` | secret | Required |
| `database.sslmode` | string | Omitted (libpq default); `disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full` |
| `database.sslrootcert` | file path | Optional absolute, readable CA file |
| `database.sslcert` | file path | Optional absolute, readable client certificate |
| `database.sslkey` | file path | Optional absolute, readable client private key |
| `authentication.mode` | string | `oidc`; `local` allowed outside production only |
| `authentication.oidc.issuer` | URL | Required in OIDC mode; HTTPS in production |
| `authentication.oidc.client_id` | string | Required in OIDC mode |
| `authentication.oidc.client_secret` | secret | Required in OIDC mode |
| `authentication.oidc.redirect_uri` | URL | Required in OIDC mode; HTTPS in production |
| `authentication.oidc.display_name_claim` | string | `preferred_username`; also `name` or `email` |
| `authentication.oidc.role_map` | mapping | `{}`; incoming role/group name to one CCI role string or list of CCI role strings |
| `consul.url` | URL | `http://127.0.0.1:8500` |
| `consul.prefix` | string | `cci`; slash-separated segments containing letters, digits, `_` or `-` |
| `consul.ca_file` | file path | Empty uses system trust; otherwise absolute and readable |
| `consul.token` | secret | Empty sends an anonymous request; no whitespace/control characters |
| `areas.<id>.name` | string | Required display name |
| `areas.<id>.encryption_key` | secret | Required Base64 encoding of exactly 32 bytes |
| `areas.<id>.filesystem.legacy_path` | directory path | Optional absolute container path; omission disables filesystem inventory for this area |
| `areas.<id>.consul` | mapping | Optional overrides for `url`, `prefix`, `ca_file`, `token` |
| `certificates.expiry_warning_days` | integer | `10`, positive; same warning window for badges, searches and dashboard |
| `certificates.reconciliation.enabled` | boolean | `true` |
| `certificates.reconciliation.missing_after_scans` | integer | `2`, minimum 2 complete scans |
| `certificates.reconciliation.max_delete_percent` | integer | `20`, range 0–100 per source |
| `csr.defaults.key_algorithm` | string | `RSA`; also `EC` |
| `csr.defaults.key_size` | integer | `4096`; RSA: 2048/3072/4096, EC: 256/384/521 |
| `csr.defaults.digest` | string | `SHA512`; also `SHA256`, `SHA384` |
| `csr.defaults.country` | string | Empty; otherwise two uppercase letters |
| `csr.defaults.state` | string | Empty |
| `csr.defaults.locality` | string | Empty |
| `csr.defaults.organization` | string | Empty |
| `csr.defaults.organizational_unit` | string | Empty |
| `puppetdb.enabled` | boolean | `false` |
| `puppetdb.url` | URL | Required when enabled; base path allowed, without query, fragment or embedded credentials |
| `puppetdb.inventory.fact_name` | string | `certificates`, nonempty when enabled |
| `puppetdb.inventory.fingerprint_field` | string | `fingerprint`, nonempty when enabled |
| `puppetdb.inventory.fingerprint_algorithm` | string | `sha256`; also `sha1` |
| `puppetdb.inventory.query` | string | Empty generates the complete inventory PQL query |
| `puppetdb.tls.ca_file` | file path | Empty uses system trust |
| `puppetdb.tls.cert_file` | file path | Empty; client certificate, paired with `key_file` |
| `puppetdb.tls.key_file` | file path | Empty; unencrypted client key |
| `puppetdb.authentication.token` | secret | Empty; optional `X-Authentication` token |
| `puppetdb.request.timeout` | integer | `30`, positive; per-read/write seconds, connect capped at 5 seconds |
| `puppetdb.request.max_response_bytes` | integer | `52428800`, positive (50 MiB) |
| `integrations.zabbix.enabled` | boolean | `false` |
| `integrations.zabbix.token` | secret | Required when enabled |
| `integrations.zabbix.certificate_sources` | string | `consul`; also `filesystem`, `both` |
| `integrations.writer.client_id` | string | `puppet`; standalone CLI provenance marker |
| `integrations.writer.actor` | string | Empty; optional standalone CLI audit actor |
| `integrations.writer.key_password` | secret | Empty; optional standalone CLI source-key password |
| `indexer.interval_seconds` | integer | `60`, positive; delay after each completed pass |

All TLS files used by an enabled integration must be readable at startup.
PuppetDB credentials require HTTPS. Server certificate and hostname verification
remain enabled. URL credentials, query strings and fragments are rejected.
Database connect and checkout timeouts remain three seconds.

## Secrets and file mounts

Every field marked **secret** accepts a direct string or exactly one `file` key:

```yaml
consul:
  token: "DIRECT_TOKEN"
areas:
  global:
    name: Global
    encryption_key:
      file: /run/secrets/global-key
    consul:
      token:
        file: /run/secrets/global-consul-token
```

Use absolute paths inside the consumer's filesystem. One terminal LF or CRLF
is removed from a secret file; other bytes are preserved. Missing/unreadable
files stop startup. `ENC[...]` is rejected: resolve encrypted deployment values
outside CCI-UI. There is no PKCS7 resolver or additional secret service.
Existing Base64 area keys and AES-256-GCM envelopes remain unchanged.

Protect YAML and secret files against unauthorized reading and modification;
allow the container UID `10001` to read them. For a local Linux file owned by
your login user, `setfacl -m u:10001:r config.yml` grants that specific UID
read access without making the file world-readable. Apply appropriate access
to referenced files and directories too, or use operator-managed ownership.
Mount files/directories read-only.
Never put real configuration under version control or into the image build
context. `.dockerignore` excludes root `config.yml`, `config.local.yml` and
`secrets/`; keep any custom secret paths outside the context too.

```yaml
services:
  web:
    environment:
      CCI_CONFIG_FILE: /etc/cci/config.yml
    volumes:
      - ./config.yml:/etc/cci/config.yml:ro
      - ./secrets:/run/secrets:ro
      - ./tls:/run/tls:ro
```

Apply the same mounts to indexer and migration services, which also validate the
complete configuration. A path string does not mount the referenced file.

## Area identity and multiple Consul clusters

Area IDs are the YAML keys: lowercase letter, then lowercase letters, digits or
underscores, maximum 48 characters. Keep existing IDs stable: they are part of
roles, Consul paths, persisted references and authenticated encryption contexts.
Changing a display name is independent. Removing an area hides access while
retaining its existing database and Consul data.

The effective connection is global `consul` plus explicit `areas.<id>.consul`
overrides. This applies equally to reads, writes, indexing, health checks,
imports and CSR publication. Each area-bound connection rejects foreign keys.
A 403, ACL-filtered response or connection failure never retries with a global
or another area's credential. An explicit empty token selects anonymous access;
it does not inherit the global token. Set URL, prefix, CA and token together
for an independent cluster. See the complete two-cluster example in
[config.example.yml](../config.example.yml).

Resolve prepared or unconfirmed publication intents before moving an area to
another cluster or prefix. Editing configuration does not migrate stored
certificate material.

New imports and CSR creation/publication accept exactly one target area.
There is no replication or transaction spanning clusters. Identical X.509
material may be managed independently in different areas. Historical multi-area
CSR rows and audit records remain unchanged and readable with their existing
all-target CSR authorization; further publication is refused. No migration
rewrites old publication receipts or duplicates requests.

Example ACL for one area's web/indexer credential (replace literal IDs/prefix):

```hcl
key_prefix "cci/global/certids/" { policy = "write" }
key_prefix "cci/global/certs/"   { policy = "write" }
key_prefix "cci/global/keys/"    { policy = "write" }
```

Public-only consumers need `read` on `certids/` and `certs/`; private-key consumers
also need `keys/` and the independent encryption key. Do not grant root-prefix
access. Failed area scans preserve previous rows; other areas can still refresh.

## Minimal local example

These are public synthetic keys for disposable data only. Generate fresh keys
with `bin/setup-local` for actual local use.

```yaml
version: 1
authentication:
  mode: local
database:
  host: db
  name: certui_development
  username: certui
  password: certui
consul:
  url: http://consul:8500
areas:
  global:
    name: Global
    encryption_key: cnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnI=
```

## Manual transfer of previous settings

Move existing values without changing their bytes. There is no ENV fallback.
In particular, preserve area encryption keys and the session secret.

| Previous setting | YAML destination |
| --- | --- |
| `DATABASE_URL`, `TEST_DATABASE_URL` | Split host, port, database, username, decoded password and TLS options into `database`; use separate YAML files for isolated environments |
| `AUTH_MODE`, `OIDC_*` | `authentication.mode` and matching `authentication.oidc` fields; decode the role-map JSON into a native YAML mapping |
| `CCI_AREAS`, `CCI_AREA_KEYS`, `<ID>_KEY`, `CCI_LEGACY_PATHS` | Combine under `areas.<id>.name`, `.encryption_key`, `.filesystem.legacy_path` |
| `CONSUL_*`, `CCI_CONSUL_TOKENS` | Global `consul` and native `areas.<id>.consul.token` overrides |
| `CCI_CERTIFICATE_EXPIRY_WARNING_DAYS`, `CCI_FILESYSTEM_RECONCILIATION` | `certificates.expiry_warning_days` and native `certificates.reconciliation` mapping |
| `CSR_DEFAULT_*` | `csr.defaults` fields |
| `PUPPETDB_*` | `puppetdb.enabled`, `.url`, `.inventory`, `.tls`, `.authentication`, `.request` |
| `CCI_ZABBIX_*` | `integrations.zabbix` |
| `INDEX_INTERVAL` | `integrations.writer.client_id` | string | `puppet`; standalone CLI provenance marker |
| `integrations.writer.actor` | string | Empty; optional standalone CLI audit actor |
| `integrations.writer.key_password` | secret | Empty; optional standalone CLI source-key password |
| `indexer.interval_seconds` |
| `PORT`, `RAILS_MAX_THREADS`, `ALLOWED_HOSTS`, `SECRET_KEY_BASE`, `LOG_LEVEL`, `CCI_HEALTH_TOKEN`, `CCI_SHOW_ERROR_DETAILS` | Matching `server` fields |
| Puppet compiler `CCI_CONSUL_URL`, `CCI_CONSUL_PREFIX`, `CCI_<AREA>_CONSUL_TOKEN` | `consul.url`, `consul.prefix`, `areas.<id>.consul.token` in its YAML configuration |
| `CCI_CERTIFICATE_AREA_MODE` | Removed; every new operation uses one area |
| `CCI_CLIENT_ID`, `CCI_ACTOR`, `KEY_PASSWORD` in examples | `integrations.writer.client_id`, `.actor`, `.key_password`; Ruby methods also accept explicit operation arguments |

Allowed process/bootstrap values are `CCI_CONFIG_FILE`, `RAILS_ENV`, standard
Ruby/Bundler/container variables and build metadata `APP_VERSION`,
`APP_REVISION`, `APP_BUILD_TIME`. `CCI_PROCESS` is an internal log process marker.
Compose-only variables such as `CCI_IMAGE`, `POSTGRES_PASSWORD`, `LEGACY_PATH`,
`CCI_HTTP_PORT` and `CCI_CONTAINER_PORT` configure infrastructure. If changing
`server.port`, match the published container target port. They do not override
application YAML settings.
