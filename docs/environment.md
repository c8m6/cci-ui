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
| `CCI_CERTIFICATE_AREA_MODE` | `multiple` (default) allows one imported or CSR-issued certificate in several areas. `single` requires exactly one selected area and rejects a fingerprint already retained in another area. |
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
| `OIDC_ROLE_MAP` | JSON object whose keys are exact incoming group/role names and whose values are application role strings or arrays of strings. Unmapped names are accepted if they are valid application roles. Empty, whitespace-only and omitted values are treated as `{}` (no translation). See [JSON format, claim sources and examples](installation.md#oidc_role_map-json-format). |
| `OIDC_DISPLAY_NAME_CLAIM` | OIDC claim shown as the signed-in user name. Allowed values are `preferred_username`, `name` and `email`. Empty or omitted values default to `preferred_username`. Missing or blank values fall back through `preferred_username`, `name`, `email` and finally the stable OIDC UID. This setting affects display only. |
| `SECRET_KEY_BASE` | Rails session secret, required in production. Development has a local fallback. Changing it invalidates sessions. |
| `ALLOWED_HOSTS` | Comma-separated allowed request hostnames. Required in production; development adds `localhost,127.0.0.1` by default. |
| `RAILS_ENV` | Rails environment. The Compose templates set `development` or `production`. Set explicitly with `docker run`. |
| `LOG_LEVEL` | Global application log level. Default: `INFO`. Use `DEBUG` for detailed Keycloak, PuppetDB, Consul and indexer diagnostics. Invalid values produce a startup warning and fall back to `INFO`. Restart services after changing it. |
| `CCI_SHOW_ERROR_DETAILS` | `true` / `1` shows exception messages and stack traces on error pages. Default: `false`, including in development. Applies to all visitors, including users who are not signed in. Errors are logged regardless of this setting. Restart the web service after changing it. |
| `PORT` | Puma listening port. Default: `3000`. Compose publishes the same port on `127.0.0.1`. |
| `RAILS_MAX_THREADS` | Puma thread count and database connection pool size. Default: `5`. |
| `CCI_CA_INVENTORY_ENABLED` | `true` / `1` enables CA discovery after each index pass and the CA certificates page. Default: `false`. Set identically for web and indexer. See [CA inventory](ca-inventory.md). |
| `INDEX_INTERVAL` | Seconds the indexer waits between completed indexing passes. Default: `60`. |

The image build supplies `APP_VERSION`, `APP_REVISION` and `APP_BUILD_TIME`.
They identify the release tag, exact source commit and UTC build timestamp.
Local builds default to `development`, `unknown` and `unknown`. Deployments
should use the values embedded in the published image rather than overriding
them at runtime. The application does not require a Git checkout in the
container.

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

Web and indexer write one JSON object per line to standard output. Every entry
contains `timestamp`, `level`, `logger` and a human-readable `message`.
Context is represented by separate fields such as `operation`, `http_status`,
`endpoint`, `duration_ms`, `user`, `client_id` and `realm`. Errors also contain
`error_type` and `error_message`. ERROR entries include their stack trace as a
JSON array instead of additional plain-text lines.

Follow both container logs with:

```bash
docker compose -f compose.yml logs -f web indexer
```

`LOG_LEVEL` defaults to `INFO`. INFO contains request completion summaries,
startup health results, complete index passes and audited business actions.
Rails SQL, transaction internals and generic model callbacks are disabled at
every level. Set `LOG_LEVEL=DEBUG` and recreate the services when diagnosing
an integration:

```bash
LOG_LEVEL=DEBUG docker compose -f compose.yml up -d --force-recreate web indexer
docker compose -f compose.yml logs -f web indexer
```

DEBUG adds source-level index progress and safe Consul write outcomes. For
Keycloak it records OIDC phases, discovery, token and user-info requests and
upstream HTTP status. After a successful provider response, logger
`cci.authorization` records the stable user UID, resolved display name and its
claim source, the relevant claim paths that were checked and found, role sources,
realm roles and client roles for
`OIDC_CLIENT_ID`, matching `OIDC_ROLE_MAP` entries, mapped roles, discarded
roles and effective application roles. It then records `decision` as
`granted`, `denied` or `continued`, while `reason` contains the concrete state.

The callback requires an authenticated identity and at least one effective
CCI-UI application role. A user without incoming roles is denied with
`no_roles_received`; a user whose incoming roles do not map to an application
role is denied with `required_role_missing`. In both cases CCI-UI clears the
session, shows that no permissions were assigned and returns the user to the
login page. Protected actions log their concrete `reason` immediately before
CCI-UI returns HTTP 403. Callback failures use distinct
reasons including `authentication_failed`, `identity_missing`,
`required_claim_missing`, `user_not_found` and `user_disabled`. A Keycloak 401
or 403 instead uses `result` value `upstream_authentication_rejected`, making an
upstream rejection distinguishable from a CCI-UI decision.

`OIDC_ROLE_MAP` and `OIDC_DISPLAY_NAME_CLAIM` are validated once during
application startup. Invalid role-map JSON, non-object JSON and values other
than strings or arrays of strings stop startup with a configuration error that
omits the configured content. An unsupported display-name claim also stops
startup and lists the supported claim names.

Malformed OIDC JSON is attributed to the concrete operation and endpoint. The
log includes the HTTP status, content type and response size, but never the
response body. An identity response that cannot be decoded reports
`oidc_phase` as `identity_response_parsing`, together with its compact format
and segment count. Three segments identify a signed JWT, five identify an
encrypted JWE, and any other count identifies unexpected compact serialization.

PuppetDB logs transport and comparison separately. A successful query reports
`resource_count` and either `data` or `no_data`. The comparison reports
`diff_count` and one of `updated`, `no_difference` or `no_data`. Connection
failures, upstream HTTP errors and responses that cannot be processed use the
distinct results `unreachable`, `http_error` and `unprocessable_response`.
WARNING and ERROR remain visible at the default INFO level.

Each incoming HTTP request receives a validated request ID. A safe
`X-Request-ID` supplied by the caller is retained, otherwise the application
generates a UUID. All application events during that request contain
`request_id`, and outgoing Keycloak, PuppetDB and Consul calls receive the same
value as `X-Request-ID`. Index passes use `correlation_id` to connect their
entries when no HTTP request exists.

Tokens, authorization and cookie headers, passwords, client secrets, area
keys, private keys, JWTs, URL queries and request or response bodies are not
logged. The central formatter also redacts configured secret values if a
framework exception includes one. Do not enable raw HTTP debug logging.

At container startup, web and indexer run dependency diagnostics and database
readiness checks. Failed checks identify the service, safe endpoint and file
metadata, the structured exception chain and diagnostic reasons such as a
missing mount, DNS failure, connection refusal or TLS verification failure.
Dependency failures are reported but do not stop startup. A Rails boot failure
is logged and exits. The web container still uses `/ready` for its recurring
Docker healthcheck. Failures returned by `/health` or `/ready` use the same
JSON error schema.

If the application cannot initialize its logger, the Ruby or container runtime
may still emit a fallback line. Once Rails has booted, application and
framework messages use the shared JSON formatter.

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
  -e RAILS_ENV -e AUTH_MODE -e PORT -e RAILS_MAX_THREADS -e LOG_LEVEL -e CCI_SHOW_ERROR_DETAILS
  -e CCI_AREAS -e CCI_LEGACY_PATHS -e CCI_AREA_KEYS
  -e DATABASE_URL -e SECRET_KEY_BASE -e ALLOWED_HOSTS
  -e CONSUL_URL -e CONSUL_TOKEN -e CONSUL_PREFIX -e CONSUL_CA_FILE
  -e OIDC_ISSUER -e OIDC_CLIENT_ID -e OIDC_CLIENT_SECRET
  -e OIDC_REDIRECT_URI -e OIDC_ROLE_MAP -e OIDC_DISPLAY_NAME_CLAIM
  -e INDEX_INTERVAL -e CCI_CA_INVENTORY_ENABLED
  -e PUPPETDB_ENABLED -e PUPPETDB_URL -e PUPPETDB_QUERY
  -e PUPPETDB_FACT_NAME -e PUPPETDB_FINGERPRINT_FIELD -e PUPPETDB_FINGERPRINT_ALGORITHM
  -e PUPPETDB_CA_FILE -e PUPPETDB_CLIENT_CERT_FILE -e PUPPETDB_CLIENT_KEY_FILE
  -e PUPPETDB_TOKEN -e PUPPETDB_TIMEOUT -e PUPPETDB_MAX_RESPONSE_BYTES
)
inventory=(--mount type=bind,src=/mnt/certificates,dst=/legacy)
inventory_readonly=(--mount type=bind,src=/mnt/certificates,dst=/legacy,readonly)

# Run once per deployment and stop if this command fails.
docker run --rm "${app_env[@]}" "${CCI_IMAGE:?Set the application image}" ruby bin/rails db:prepare

docker run -d --name cci-web --restart unless-stopped \
  "${app_env[@]}" "${inventory[@]}" \
  -p 127.0.0.1:3000:3000 "${CCI_IMAGE:?Set the application image}"
# Start after the migration job has succeeded.
docker run -d --name cci-indexer --restart unless-stopped \
  "${app_env[@]}" "${inventory_readonly[@]}" \
  "$CCI_IMAGE" ruby bin/indexer
```

The web image starts Puma without preparing the database. Run the migration
job once before starting or updating replicas. Supply reachable service URLs
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

## CSR defaults

These environment variables populate the CSR form and apply to omitted API
fields. Users may override them. Empty subject fields are omitted. Existing
`CCI_AREA_KEYS` (or the existing area-key fallback) encrypt both the private key
and revoke password. There is no separate CSR secret or static revoke password.

| Variable | Default | Allowed values or purpose |
| --- | --- | --- |
| `CSR_DEFAULT_KEY_ALGORITHM` | `RSA` | `RSA` or `EC` |
| `CSR_DEFAULT_KEY_SIZE` | `4096` | RSA: 2048, 3072, 4096. EC: 256, 384, 521. Configure both algorithm and size when switching to EC. |
| `CSR_DEFAULT_DIGEST` | `SHA512` | `SHA256`, `SHA384`, `SHA512` |
| `CSR_DEFAULT_COUNTRY` | empty | Two uppercase country-code letters |
| `CSR_DEFAULT_STATE` | empty | State or province |
| `CSR_DEFAULT_LOCALITY` | empty | Locality |
| `CSR_DEFAULT_ORGANIZATION` | empty | Organization |
| `CSR_DEFAULT_ORGANIZATIONAL_UNIT` | empty | Organizational unit |

The Compose web and indexer services receive the same defaults. See
[CSR operations](csr.md) for validation, roles, persistence and rotation.

For a complete production Compose template with inline values, external services
and a reduced indexer environment, see [inline Compose configuration](compose-full.md).
