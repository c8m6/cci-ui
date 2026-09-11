# Implementation of the change requests

The original request list was supplied as `aenderungen.txt`.

| No. | Request | Implementation |
| --- | --- | --- |
| 1 | CCI-UI | Updated name, wordmark, page titles, favicon and documentation |
| 2 | Material-inspired dark theme | Toggle, persisted selection and system preference; slate background `hsl(232,15%,14%)`, dark surfaces `hsl(232,15%,18%)`, black navigation; light variant with Indigo / Deep Purple |
| 3 | Consul instead of Redis | Consul HTTP adapter, atomic KV transactions and Compose service; no Redis runtime dependency |
| 4 | Puppet compares actual and desired state | `cci` module, native file resources with SHA-256, deterministic PEM contents and a version pinned per compile |
| 5 | Lookup in search results | Dedicated column; also included in search |
| 6 | Additional role for private keys | `<area_id>_key_exporter` in addition to Writer, enforced server-side |
| 7 | Upload to multiple authorized areas | Multi-selection with permission checks before preview and save; separate encryption |
| 8 | Technical documentation | `docs/technik.md`, describing architecture rather than screen operation |
| 9 | Installation guide | `docs/installation.md`, covering local setup, SSO and production preparation |
| 10 | Readers cannot export | Download endpoint rejects all Reader exports; no export actions or raw PEM blocks for Readers |
| 11 | Remove the bottom-right notice | Removed |
| 12 | Hiera code in certificate details | Files: `issuer` and `subject`, including tags; Consul: `cci::certificates` with area and lookup |
| 13 | Link chain certificates | Links to matching accessible entries in the same area; missing entries are explained |

Item 12 still mentioned Redis. Following the confirmed switch in item 3, the
lookup variant applies to Consul. The requested `issue` field is implemented as
`issuer`, matching the actual legacy field.

Background colors were checked against the
[Material slate palette](https://github.com/squidfunk/mkdocs-material/blob/master/src/templates/assets/stylesheets/palette/_scheme.scss).
The remaining design is independent.

## Subsequent requests

- Separate Auditor roles per configured area; searchable audit logs for changes
  and exports, including user, time, certificate identities, chains and export
  options. Metadata remains available after certificate deletion.
- Configurable areas, display names and legacy file assignment in
  `config/areas.yml`. Roles, local test identities and area selectors are generated
  from configuration. Fixed area names were removed from application text and
  documentation examples.
- English documentation in `docs/`; the application UI remains German.

## Verification history

The initial implementation of the 13 requests was checked as follows:

- 17 automated tests with 132 assertions and no failures: formats, area
  separation, export roles, import previews, multi-area uploads, Consul CAS
  and consistent Puppet versions.
- Actual Puppet 8 test: initial installation `2`, unchanged second run `0`,
  renewal `2`; the file modification time stays unchanged on the second run.
- Browser checks at widths of 1440 and 390 pixels: no JavaScript/CSP errors
  or horizontal page overflow; search and theme switching worked.
- Ten simultaneous list requests with 1,673 indexed certificate blocks:
  all HTTP 200, taking 76–326 ms in the local development setup. This was a
  spot check, not a production benchmark.
- Ruby generated a JKS containing a private key; Java keytool converted it to
  PKCS#12 successfully. Ruby then read the Java output, including the key.
- After adding audit logs: 22 tests with 242 assertions passed, along with
  browser checks for audit search, dark mode and mobile layout.

The expanded suite passed with 27 tests and 295 assertions. Its area-configuration
tests use the example zones Zone A and Zone B and
cover import, private-key export, audit access, Consul/Puppet client reads,
invalid configuration and legacy assignment. The current suite is the source
of truth for subsequent verification results.

Production Keycloak and your actual compiler configuration have not yet been
connected. The Puppet 8 results above describe the earlier integration run;
the latest area generalization has also received parser and Ruby client checks,
but a new full Puppet apply run has not been completed.
