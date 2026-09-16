# Documentation screenshots

The images linked from the README are browser captures of the actual application,
using generated certificates, example domains, synthetic PuppetDB observations
and local test identities. No production certificate, hostname, credential or
user record is used. The latest captures include the optional “Hosts” column,
“Hosts laut PuppetDB” details and Consul-only status/archive controls.

## Capture environment

The [screenshot Compose file](../script/screenshots/compose.yml) builds the current
source into a separate image and runs a disposable PostgreSQL, Consul and web
stack named `cci-ui-screenshots`. It listens on `127.0.0.1:3001`; the normal
development application remains on port 3000. It does not load `.env`, mount
`data/`, reuse development databases or run a scheduled indexer.

The [seed script](../script/screenshots/seed.rb) creates certificates and real
status, archive and export audit events through application services. It passes
an anonymized synthetic response through `PuppetdbInventory` to populate the host
cache. These images demonstrate the UI and fingerprint mapping, not a connection
to a live PuppetDB instance. The public demo encryption keys apply only to this
isolated stack.

## Regenerate

Requirements: Docker with Compose, Node.js 18 or newer, and Puppeteer with its
compatible Chrome installed. Run from the repository root. For a temporary
browser installation, use:

```console
npm install --prefix /tmp/cci-screenshot-browser puppeteer@24.10.2
```

Start a fresh screenshot stack, capture all pages, then remove only that stack:

```console
docker compose -f script/screenshots/compose.yml down
docker compose -f script/screenshots/compose.yml up --build -d --wait
PUPPETEER_MODULE=/tmp/cci-screenshot-browser/node_modules/puppeteer node script/screenshots/capture.cjs
docker compose -f script/screenshots/compose.yml down
```

The initial `down` prevents reusing stale generated data. Demo storage is
ephemeral; this command does not affect the main development project. Never
point the seed script at a real database or Consul namespace. It rejects any
database other than `screenshots` and namespace other than `cci-screenshots/v1`.

`PUPPETEER_MODULE` can instead point to an existing Puppeteer installation, and
`PUPPETEER_EXECUTABLE_PATH` can select its compatible Chrome binary. The browser
captures at a width of 1800 pixels with the Europe/Berlin time zone. It checks the
host column, the three hostnames for `portal.example.test`, the adjacent status
and archive controls, and audit entries before completing. Review all images
visually after capturing; a functional assertion cannot detect every layout issue.

| File | Contents |
| --- | --- |
| `screenshots/overview.png` | Light overview, both certificate sources, Puppet status, host counts and filters |
| `screenshots/details.png` | Dark Consul details, three reported hosts, status/archive controls, versions and Hiera |
| `screenshots/audit.png` | Light audit log with archive, status, export and import events |

The capture script does not edit the page markup or styles. Certificate keys,
fingerprints, dates and event IDs are generated anew, so captures are not
byte-for-byte deterministic. Regenerate all three together after relevant UI
changes and keep their README captions consistent.
