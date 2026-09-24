# Environment configuration

All deployment-specific application settings are read from process environment
variables. Web and indexer use the same configuration. No external application
configuration file or configuration mount is required. The Rails configuration
shipped in the image remains part of the application code and reads these values.
Certificate inventories and optional TLS certificates and keys are still files.

## Areas, inventories and encryption keys

```bash
export CCI_AREAS='{"zone_a":"Zone A","zone_b":"Zone B"}'
export CCI_LEGACY_PATHS='{"zone_a":"/legacy/zone_a","zone_b":"/legacy/zone_b"}'
export CCI_AREA_KEYS='{"zone_a":"<existing Base64 key>","zone_b":"<existing Base64 key>"}'
```

| Variable | Meaning and application default |
| --- | --- |
| `CCI_AREAS` | Required, nonempty JSON object mapping stable area IDs to display names. IDs match `[a-z][a-z0-9_]{0,47}`; names contain 1–100 characters and cannot be whitespace-only. |
| `CCI_LEGACY_PATHS` | JSON object mapping any subset of the configured areas to absolute directories inside the container. Default: `{}` (no disk inventory). Multiple areas may have independent roots. |
| `CCI_AREA_KEYS` | JSON object mapping area IDs to Base64-encoded, exactly 32-byte encryption keys. Omitted or empty means no map entries. Required for private-key operations unless the fallback below supplies the key. |
| `<UPPERCASE_AREA_ID>_KEY` | Existing per-area fallback, for example `ZONE_A_KEY`. Used only when the area has no entry in `CCI_AREA_KEYS`. Must be injected into the application process. |

Malformed area/path JSON, unknown path area IDs and relative paths prevent
startup. Configuration is cached per process; recreate both services after
changes. Area keys are checked when used. A malformed key map raises an error;
it does not silently fall back to individual keys. Public-certificate operations
do not need encryption keys.

The Compose templates explicitly forward `CCI_AREA_KEYS`, so arbitrary new areas
need no additional environment declarations. Individual key variables exported
on the host are not automatically forwarded by Compose: pass them through its
optional `env_file`, add explicit environment entries, or use the JSON map.
Standalone Ruby writers and the packaged Puppet client accept the same map and
fallback variables.

The development Compose template supplies example defaults for `CCI_AREAS`
(`zone_a`, `zone_b`) and `CCI_LEGACY_PATHS` (`{"zone_a":"/legacy"}`). When
overriding areas, also override paths, for example with `{}`. Production Compose
requires `CCI_AREAS` and defaults `CCI_LEGACY_PATHS` to `{}`.

## Connections, authentication and runtime

| Variable | Meaning and application default |
| --- | --- |
| `DATABASE_URL` | PostgreSQL connection URL. Set explicitly for deployment. The development fallback is `postgresql://certui:certui@127.0.0.1:55432/certui_development`; development Compose supplies its internal `db` connection. |
| `CONSUL_URL` | Consul HTTP(S) endpoint. Application default: `http://127.0.0.1:8500`; development Compose uses `http://consul:8500`. |
| `CONSUL_TOKEN` | Consul ACL token. Default: empty for local evaluation. Production Compose requires it. |
| `CONSUL_PREFIX` | Consul KV namespace. Default: `cci`. |
| `CONSUL_CA_FILE` | Optional CA certificate path inside the container for HTTPS Consul. Empty or omitted uses system trust. Mount the certificate into both services if needed. |
| `AUTH_MODE` | `oidc` (application default) or `local`. Development Compose defaults to `local`; production Compose sets `oidc`. Production rejects local authentication. |
| `OIDC_ISSUER` | Keycloak realm URL, required in OIDC mode; production requires HTTPS. |
| `OIDC_CLIENT_ID` | OIDC client identifier, required in OIDC mode. |
| `OIDC_CLIENT_SECRET` | OIDC client secret, required in OIDC mode. |
| `OIDC_REDIRECT_URI` | Callback URL, required in OIDC mode. Development Compose defaults to `http://localhost:3000/auth/keycloak/callback`; update it for a different port or hostname. |
| `OIDC_ROLE_MAP` | JSON object mapping incoming roles/groups to one application role or an array of roles. Default: `{}`. See [Keycloak configuration](installation.md#keycloak). |
| `SECRET_KEY_BASE` | Rails session secret, required in production. Development has a local fallback. Changing it invalidates sessions. |
| `ALLOWED_HOSTS` | Comma-separated allowed request hostnames. Required in production; development adds `localhost,127.0.0.1` by default. |
| `RAILS_ENV` | Rails environment. The Compose templates set `development` or `production`. Set explicitly with `docker run`. |
| `CCI_SHOW_ERROR_DETAILS` | `true` / `1` shows exception messages and stack traces on error pages. Default: `false`, including in development. Applies to all visitors, including users who are not signed in. Errors are logged regardless of this setting. Restart the web service after changing it. |
| `PORT` | Puma listening port. Default: `3000`. Compose publishes the same port on `127.0.0.1`. |
| `RAILS_MAX_THREADS` | Puma thread count and database connection pool size. Default: `5`. |
| `CCI_CA_INVENTORY_ENABLED` | `true` / `1` enables CA discovery after each index pass and the CA certificates page. Default: `false`. Set identically for web and indexer. See [CA inventory](ca-inventory.md). |
| `INDEX_INTERVAL` | Seconds the indexer waits between completed indexing passes. Default: `60`. |

Consul tokens, OIDC secrets and encryption keys are supplied directly through
the environment. Optional PuppetDB TLS credentials use the file paths below.
Keep area key bytes stable so stored private keys remain decryptable.

### Error pages and diagnostics

HTTP error pages use the application layout and the selected German or English
language. This includes unhandled Ruby/Rails exceptions, missing routes and
certificates, permission errors, invalid requests and an unavailable certificate
store. HTTP status codes are preserved. HEAD responses have no body.

With `CCI_SHOW_ERROR_DETAILS=false`, pages show a general explanation and a
request ID. Exception messages, source locations and stack traces are hidden.
Set `CCI_SHOW_ERROR_DETAILS=true` to include technical diagnostics in the same
layout. This is a deployment setting, not a user preference. It can expose
internal information to any visitor, so enable it only in a trusted environment.
Ordinary validation messages, such as an invalid certificate or missing input,
remain visible so users can correct their input.

Rails logs unhandled exceptions independently of the display setting, including
their class, message and backtrace. Handled import and certificate errors are
also logged. Logs use the configured Rails logger, by default
`log/<RAILS_ENV>.log` inside the application container. For example:

```bash
docker compose -f compose.yml exec -T web tail -n 100 log/development.log
```

If the application cannot start, or the error layout itself fails, Rails or the
web server must provide its fallback response. Those failures cannot use the
application layout. The error renderer does not query the database or Consul.

## Optional PuppetDB host inventory

The feature is disabled by default. Configure the same settings in web and
indexer; web reads cached results only, while the scheduled indexer queries
PuppetDB after indexing certificates. Setting `PUPPETDB_ENABLED=false` hides the
host column and detail section and stops PuppetDB requests without erasing the
cached associations. Recreate both services after configuration changes.

| Variable | Meaning and application default |
| --- | --- |
| `PUPPETDB_ENABLED` | `true` / `1` enables synchronization and UI; `false` / `0` disables it. Default: `false`. |
| `PUPPETDB_URL` | Required when enabled. HTTP(S) base URL, for example `https://puppetdb.example.test:8081`. The client appends `/pdb/query/v4`; optional reverse-proxy base paths are preserved. Embedded credentials, query strings and fragments are rejected. |
| `PUPPETDB_FACT_NAME` | Fact containing certificate fingerprints. Default: `certificates`, an anonymized example name; set this to your actual custom fact name. |
| `PUPPETDB_QUERY` | Optional PQL query returning a complete array of objects with `certname` and `facts`. Empty or omitted generates the inventory query below using `PUPPETDB_FACT_NAME`. Do not add pagination limits or offsets. |
| `PUPPETDB_FINGERPRINT_FIELD` | Field within each certificate object containing its fingerprint. Default: `fingerprint`. Direct fingerprint strings are also supported. |
| `PUPPETDB_FINGERPRINT_ALGORITHM` | `sha256` (default, 64 hex characters) or `sha1` (40 hex characters). Must match the custom fact. The catalog identity remains SHA-256. |
| `PUPPETDB_CA_FILE` | Optional CA PEM path inside the indexer container. Empty uses system trust. Server certificate and hostname verification are always enabled for HTTPS. |
| `PUPPETDB_CLIENT_CERT_FILE` | Optional client certificate PEM path for mutual TLS. Must be paired with `PUPPETDB_CLIENT_KEY_FILE`. |
| `PUPPETDB_CLIENT_KEY_FILE` | Corresponding unencrypted private-key PEM path, readable by the container user. Mount credentials read-only. |
| `PUPPETDB_TOKEN` | Optional token sent as `X-Authentication`, for example with Puppet Enterprise RBAC. Credentials require HTTPS. |
| `PUPPETDB_TIMEOUT` | Positive integer per-read/write timeout in seconds. Default: `30`; connection establishment is capped at 5 seconds. This is not a deadline for the entire query. |
| `PUPPETDB_MAX_RESPONSE_BYTES` | Positive maximum response size. Default: `52428800` (50 MiB). Oversized responses fail without replacing cached host associations. |

Anonymized example (the custom fact name `certificates` is illustrative and does
not specify a Puppet class):

```bash
export PUPPETDB_ENABLED=true
export PUPPETDB_URL=https://puppetdb.example.test:8081
export PUPPETDB_FACT_NAME=certificates
export PUPPETDB_FINGERPRINT_ALGORITHM=sha256
export PUPPETDB_QUERY='inventory[certname,facts]{ certname in fact_contents[certname]{ name = "certificates" } }'
export PUPPETDB_CA_FILE=/run/puppetdb/ca.pem
export PUPPETDB_CLIENT_CERT_FILE=/run/puppetdb/client.pem
export PUPPETDB_CLIENT_KEY_FILE=/run/puppetdb/client.key
```

The generated default query is equivalent to this example. If you change the
fact name and override the query, update both settings to agree. Other queries
may restrict the host population, but must retain the `certname` and `facts`
projection and return the configured fact for every row. The selected hosts
define the scope of the displayed counts; hosts outside the query do not count.

The Compose templates forward these variables to both services. Add a read-only
mount for the TLS directory to the indexer, for example through an override:

```yaml
services:
  indexer:
    volumes:
      - /srv/cci/puppetdb-tls:/run/puppetdb:ro
```

Use a client identity authorized to read the selected facts. The application
only calls the query API, never PuppetDB's command API. No Puppet class is
installed or renamed by this feature. See [PuppetDB host mapping](puppetdb.md)
for the supported fact shapes, synchronization behavior and UI semantics.

## Optional Compose settings

These variables configure container infrastructure rather than application logic.
The templates require Compose 2.24 or newer for optional environment files.

| Variable | Meaning |
| --- | --- |
| `CCI_ENV_FILE` | Optional service environment file. Defaults to `.env` in development and `.env.production` in production. Missing files are accepted. For Compose substitutions from a custom file, also supply `--env-file <path>`. |
| `CCI_IMAGE` | Production image reference; default `cci-ui:local`. |
| `POSTGRES_PASSWORD` | Password for the bundled PostgreSQL service. Required in production; development default `certui`. The production `DATABASE_URL` must contain the corresponding URL-encoded password. |
| `LEGACY_PATH` | Production Compose host directory mounted at `/legacy`, read/write for web and read-only for the indexer. Required by that template, even if `CCI_LEGACY_PATHS` is `{}`. Use a readable empty directory in that case, or omit inventory mounts in your own container service definition. This variable no longer selects application inventory roots. |

Development Compose mounts `./data` at `/legacy`. Multiple inventories below
that parent can be selected entirely through `CCI_LEGACY_PATHS`. Inventories on
other host paths need the corresponding container mounts; see
[mount examples](installation.md#configuring-areas).

`.env` and `.env.production` are optional conveniences. To ignore any existing
files while using exported variables:

```bash
export CCI_ENV_FILE=/path/that/does/not/exist
docker compose --env-file /dev/null -f compose.production.yml up -d
```

For a **new local installation**, the setup helper can generate environment
exports without creating a file:

```bash
eval "$(ruby bin/setup-local --stdout)"
docker compose -f compose.yml up --build -d --wait
```

Store those generated keys for future starts. Running the helper again generates
different keys, so use the stored values for subsequent starts. Without `--stdout`,
the helper creates an optional `.env` with mode `0600`, leaving existing files
untouched.

## Running without deployment configuration files

The following Bash example uses an existing PostgreSQL service, Consul and
Keycloak. Export the required values from the tables above through your deployment
environment first, including `DATABASE_URL`, `SECRET_KEY_BASE`, `ALLOWED_HOSTS`,
Consul credentials, OIDC settings and area keys. No Compose or env file is used:

```bash
export RAILS_ENV=production
export AUTH_MODE=oidc
export PORT=3000
export CCI_AREAS='{"zone_a":"Zone A","zone_b":"Zone B"}'
export CCI_LEGACY_PATHS='{"zone_a":"/legacy/zone_a","zone_b":"/legacy/zone_b"}'

app_env=(
  -e RAILS_ENV -e AUTH_MODE -e PORT -e RAILS_MAX_THREADS -e CCI_SHOW_ERROR_DETAILS
  -e CCI_AREAS -e CCI_LEGACY_PATHS -e CCI_AREA_KEYS
  -e DATABASE_URL -e SECRET_KEY_BASE -e ALLOWED_HOSTS
  -e CONSUL_URL -e CONSUL_TOKEN -e CONSUL_PREFIX -e CONSUL_CA_FILE
  -e OIDC_ISSUER -e OIDC_CLIENT_ID -e OIDC_CLIENT_SECRET
  -e OIDC_REDIRECT_URI -e OIDC_ROLE_MAP -e INDEX_INTERVAL -e CCI_CA_INVENTORY_ENABLED
  -e PUPPETDB_ENABLED -e PUPPETDB_URL -e PUPPETDB_QUERY
  -e PUPPETDB_FACT_NAME -e PUPPETDB_FINGERPRINT_FIELD -e PUPPETDB_FINGERPRINT_ALGORITHM
  -e PUPPETDB_CA_FILE -e PUPPETDB_CLIENT_CERT_FILE -e PUPPETDB_CLIENT_KEY_FILE
  -e PUPPETDB_TOKEN -e PUPPETDB_TIMEOUT -e PUPPETDB_MAX_RESPONSE_BYTES
)
inventory=(--mount type=bind,src=/mnt/certificates,dst=/legacy)
inventory_readonly=(--mount type=bind,src=/mnt/certificates,dst=/legacy,readonly)

docker run -d --name cci-web --restart unless-stopped \
  "${app_env[@]}" "${inventory[@]}" \
  -p 127.0.0.1:3000:3000 "${CCI_IMAGE:?Set the application image}"
# Start after web has prepared the database and responds through the proxy.
docker run -d --name cci-indexer --restart unless-stopped \
  "${app_env[@]}" "${inventory_readonly[@]}" \
  "$CCI_IMAGE" ruby bin/indexer
```

The web image prepares the database at startup. Supply reachable service URLs
and container networking for your infrastructure and put an HTTPS reverse proxy
in front of the published port. With no disk inventory, set
`CCI_LEGACY_PATHS='{}'` and omit the `inventory` arguments. Add a read-only CA
mount to both commands when using `CONSUL_CA_FILE`.
For PuppetDB client certificates or a private CA, also mount their directory
read-only into the indexer command, for example
`--mount type=bind,src=/srv/cci/puppetdb-tls,dst=/run/puppetdb,readonly`, and set
the `PUPPETDB_*_FILE` paths to the corresponding container paths. Forwarding a
file path in an environment variable does not mount the file itself.

## Test and standalone writer variables

`TEST_DATABASE_URL` selects the isolated Rails test database. `TEST_IMAGE`
selects the image used by `compose.ci.yml`. Tests supply synthetic areas and
an isolated Consul namespace.

The standalone example writer also uses `CCI_CLIENT_ID` and `CCI_ACTOR` for
write provenance, and optional `KEY_PASSWORD` for the input private-key file.
These are separate from the OIDC client settings. See
[Ruby import examples](consul-schema.md).
