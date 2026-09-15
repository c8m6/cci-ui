# Implementation of the change requests

The original request list was supplied as `aenderungen.txt`.

| No. | Request | Implementation |
| --- | --- | --- |
| 1 | CCI-UI | Updated name, wordmark, page titles, favicon and documentation |
| 2 | Material-inspired dark theme | Toggle, persisted selection and system preference; slate background `hsl(232,15%,14%)`, dark surfaces `hsl(232,15%,18%)`, black navigation; light variant with Indigo / Deep Purple |
| 3 | Consul storage | Consul HTTP adapter, atomic KV transactions and Compose service |
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

The requested `issue` field in item 12 is implemented as `issuer`, matching
the actual legacy field.

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

- Explicit overwrite confirmation for existing area/lookup pairs, enforced by
  the server and bound to the previewed Consul modification index.
- `active`, `norollout`, and `delete` status for both Consul and legacy
  certificates, with Writer-only editing, independent list filtering and audit
  events. Legacy files remain unchanged; their status metadata is kept in Consul.
  Puppet execution of the status contract is deferred.
- Removed the obsolete storage proposal and normalized audit migrations to the
  current Consul terminology. See [the complete schema](consul-schema.md).

- Automatic cleanup of legacy Consul status keys after the last disk copy is
  removed, with complete-scan checks and Consul CAS protection.
- UI upload rejection for certificates already in the actual disk inventory,
  checked by DER fingerprint before preview and commit across destination areas.
  Incomplete inventory scans block uploads and prevent destructive cleanup.

## Verification history

The legacy cleanup and duplicate-upload update passes 58 automated tests with
514 assertions and no failures or errors against isolated PostgreSQL and Consul.
It covers last-copy removal, file moves, PEM bundle changes, stale or lost search
indexes, missing and unreadable directories, malformed PEM, concurrent status
changes, cleanup across multiple Consul transactions, cross-area upload rejection,
DER uploads, batch rejection and changes between preview and commit.

The status and overwrite-confirmation update passes 44 automated tests with
446 assertions and no failures or errors against isolated PostgreSQL and Consul.
Coverage includes server-enforced confirmation, concurrent lookup changes,
legacy draft rejection, status persistence across renewal and index rebuilds,
legacy file immutability, status filtering, permissions, audit metadata, and
compatibility with older lookups without status. Puppet status execution is
outside this release's scope.

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
