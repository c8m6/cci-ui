# Deleting filesystem certificates

Writers can open a filesystem certificate and select **Delete filesystem
certificate** (**Dateizertifikat löschen** in German). A separate confirmation
page lists the affected files, the number of certificates in the PEM file and
the consequences. The server requires the confirmation checkbox and a signed
confirmation token that expires after fifteen minutes. Readers, key exporters
and writers from other areas cannot perform this action.

The UI describes the operation as deletion and lists the affected original
filenames. Renaming and retained backup filenames are implementation details
documented here. Audit records retain the complete old/new filename mapping,
while the audit page displays the original filenames.

## Scope and retained data

The action retires the complete PEM file, not an individual certificate block.
All catalog rows for that file in the area are marked with `deleted_at` and
`active: false`. The PEM and any same-stem `.key` and `.tag` companions are
renamed in place:

```text
fff4aeb517b447b65d633e484c64985a.key -> fff4aeb517b447b65d633e484c64985a.key.DELETED
fff4aeb517b447b65d633e484c64985a.tag -> fff4aeb517b447b65d633e484c64985a.tag.DELETED
fff4aeb517b447b65d633e484c64985a.pem -> fff4aeb517b447b65d633e484c64985a.pem.DELETED
```

Missing companion files are allowed. Embedded private keys remain in the renamed
PEM. No certificate or key bytes are destroyed. Names ending in `.DELETED` no
longer match the original filenames used by Puppet and the legacy UI. Existing
copies on target hosts are not removed by this action.

Deleted entries disappear from overview counts, searches, detail routes, exports
and CA discovery. The area's cached CA page and Hiera output are invalidated
immediately and rebuilt by the next index pass. Audit history remains accessible
to the area's auditors. No Consul record or Puppet rollout status is written.
The existing Consul archive workflow is separate.

Reindexing does not reactivate deleted catalog rows, even if the original files
are manually restored. There is no UI restore action. Recovery is an explicit
administrator operation involving both the files and their PostgreSQL tombstones.
Back up PostgreSQL together with the legacy inventory.

## Mounts and permissions

The web container needs a read/write legacy mount and permission as UID 10001
to rename the files within their parent directories. The indexer only needs read
access and retains its read-only mount. Configure NFS permissions and ACLs for
the web service accordingly. Startup health checks verify readability, not
whether deletion is permitted.

Each area must have a separate inventory root for deletion. Overlapping roots,
symbolic links and hard-linked files are rejected. An unavailable inventory
does not authorize deletion. Missing files or mounts are never interpreted as
a request to hide the entire catalog.

## Audit and failure handling

Before changing files, the application verifies the certificate fingerprint and
the file identities and metadata shown at confirmation time. Changes invalidate
the confirmation. Indexing and deletion share a PostgreSQL advisory lock.

The audit event records the actor, area, certificate identities and old/new
relative filenames before the first rename, with outcome `pending`. It never
contains PEM or private-key material. Successful completion records `succeeded`.
The Linux `renameat2` operation uses `RENAME_NOREPLACE`, so an existing target is
never overwritten. A filesystem without support for this operation fails closed.

A bundle spans multiple files and PostgreSQL, so the operation is not atomic
across those systems. On an ordinary failure the application attempts to restore
already-renamed files and rolls back the catalog changes. The audit outcome is
`unknown` and must be checked before retrying. A process crash can leave a
`pending` event or a partially renamed bundle. An administrator must reconcile
the listed files and catalog rows before retrying. Rollback also refuses to
overwrite existing files. Coordinate external writers during deletion because
they do not participate in the application lock.

## Automatic filesystem reconciliation

The existing indexer reconciles manually removed or moved filesystem certificates
after a complete scan of each configured `CCI_LEGACY_PATHS` source. This phase
only changes PostgreSQL; it never writes to the inventory or changes Consul.
The confirmed UI rename workflow above continues to retain `deleted_at`
tombstones, which automatic reconciliation never deletes or reactivates.

`CCI_FILESYSTEM_RECONCILIATION` uses the existing environment JSON configuration:

```dotenv
CCI_FILESYSTEM_RECONCILIATION='{"enabled":true,"missing_after_scans":2,"max_delete_percent":20}'
```

After the first complete scan without a previously observed certificate, its
`filesystem_missing_scans` becomes 1. The second successful absence confirms
deletion. Finding the same relative PEM/block ID and SHA-256 fingerprint resets
the counter to zero. Failed scans leave counters unchanged and do not count as
confirmation; two confirmations can therefore span a failed pass. A renamed
file or changed bundle block is a new identity; its previous identity follows
the same guarded cleanup. Thresholds greater than 2 extend the grace period.
Disabling reconciliation preserves missing counters while indexing present
material; complete rediscovery still resets the counter.

The source scan must enumerate every relevant directory and read every PEM and
its applicable tag metadata. Observed I/O errors, permission failures, timeouts,
invalid or empty certificate PEM files, disappearing entries and changes in
file/directory metadata abort the source. No source projection, missing-counter
change or deletion commits after such a failure. Other sources may still refresh.
Final PEM and directory metadata checks run after companion reads as well, so
rediscovery or changes to already-read PEM files during those reads abort the
scan, including an administrator's fresh approval scan.
Scanning, projection and cleanup use the existing PostgreSQL advisory lock; all
database changes for one source, including audit and CA invalidation, commit or
roll back together. Process termination before commit leaves the previous state.
The lock also serializes direct refreshes and administrator cleanup.

Only retained filesystem rows bound to the area's resolved inventory root are
eligible. Consul certificates, CSRs, deletion tombstones, removed mappings and
rows of uncertain origin remain untouched. The additive migration does not
infer origins from stale paths: old rows are bound only when a complete scan
actually finds them. Previously missing, unbound rows need manual investigation.
Changing a source root cannot reuse confirmations attached to its previous root.
Removed source mappings, previous roots and unassigned retained rows produce
an area/root-scoped warning with their retained count. Readding the original
source does not itself delete anything: a successful scan first rediscovers
present identities and resets their missing state. Rows still absent remain
subject to the existing confirmation threshold and persistent deletion guard.

For an unobserved pre-migration row, an administrator must establish its
historical area/root assignment from trusted deployment records or backups.
Only after that review may the existing Rails runner assign its
`filesystem_source_path` to the verified resolved root, with
`filesystem_missing_scans: 0` and `filesystem_cleanup_blocked: false`.
Two new complete scans and the same deletion guard then apply. Do not assign
origins solely to bypass the protection for ambiguous records.

Before deletion, the indexer compares all confirmed candidates with the bound,
retained database population captured **before** the scan. Newly discovered
certificates cannot dilute this denominator within that pass. If the candidates
exceed `max_delete_percent`, all deletion for that source is blocked. At the
default limit, exactly 20% is allowed; more than 20% is blocked. Counters stop at
the confirmation threshold, and repeated blocked passes leave the population
intact. A blocked candidate also retains `filesystem_cleanup_blocked`: adding
new certificates, raising the configured limit or repeatedly reindexing cannot
silently lift an earlier block. Rediscovery resets this flag along with the
missing counter; otherwise exact administrator approval is required. If any
candidate remains blocked, all candidates in that source remain protected.
In particular, an accessible empty directory representing a lost
inventory blocks cleanup of its entire bound population. A limit of 0 blocks
automatic deletion; 100 disables the percentage guard.

This generic scan cannot establish why a readable inventory has changed. A
stable, partially missing inventory within the configured percentage limit can
be deleted after confirmation. External writers do not take the database lock,
and metadata checks cannot provide an atomic filesystem snapshot. Coordinate
writers and monitor storage failures. No mount detection, storage-type check,
marker file or inventory write is used.

Search and monitoring retain missing records until guarded deletion completes.
CA discovery skips marked-missing filesystem rows, avoiding repeated read errors;
deletion invalidates cached CA links. Cached PuppetDB observations disappear
with their certificate row. No relational foreign keys refer from CSR or audit
records to catalog certificates. Audit events retain public certificate metadata
and source references after deletion, without certificate/key bytes.

### Controlled cleanup of a legitimate mass deletion

Check storage availability, the configured root and the intended removals,
coordinate external writers, and back up PostgreSQL before approval. Wait for
two complete scans to confirm the entire missing set. Inspect IDs, paths and
fingerprints through the existing Rails runner in the indexer container:

```console
docker compose -f compose.yml exec indexer ruby bin/rails runner 'area = "zone_a"; root = LegacyStore.root(area: area).to_s; threshold = FilesystemReconciliationConfiguration.configuration.fetch("missing_after_scans"); puts Certificate.retained.where(area: area, source: "filesystem", filesystem_source_path: root).where("filesystem_missing_scans >= ?", threshold).order(:id).pluck(:id, :source_id, :fingerprint).to_json'
```

Approve the exact reviewed set and supply the responsible administrator identity.
The IDs below are examples; replace them with the complete reviewed set:

```console
docker compose -f compose.yml exec indexer ruby bin/rails runner 'FilesystemReconciliation.approve!(area: "zone_a", certificate_ids: [101, 102, 103], actor: "operator@example.test")'
```

This runs a new complete scan under the same lock. It requires the exact set of
previously confirmed, still-missing IDs; rediscovery, additional confirmed IDs,
changed roots or an incomplete scan reject approval. It bypasses only the
percentage guard for this invocation and area. It cannot shorten the confirmation
period, affect another source or enable future automatic mass deletions. A
transactional `delete` audit event records the actor, exact certificate metadata,
root, previous population, deletion percentage and `approved: true`. Scheduled
cleanup uses actor `indexer` and `approved: false`. No new public API is exposed.

### Operational logs

All messages use the existing structured JSON logger and include area, source
and operation. Relevant messages are:

| Level | Message | Meaning |
| --- | --- | --- |
| INFO | `Filesystem certificate missing; reconciliation pending` | Successful absence increased the counter; includes certificate ID, source reference and count. |
| INFO | `Stale filesystem certificate catalog record removed` | Committed cleanup removed this record. |
| WARN | `Filesystem reconciliation suspended by deletion limit` | No candidates were deleted; includes candidate count, previous population, percentage and limit. Investigate the source before approval. |
| WARN | `Filesystem records retained without a matching configured source` | Removed mappings, changed roots or unknown origins leave rows untouched; includes area, previous root and retained count. |
| ERROR | `Filesystem scan incomplete; reconciliation skipped` | Source refresh failed; previous catalog and missing counters remain intact. |

Blocked passes repeat the warning without repeated material-read errors from CA
discovery. Counter and deletion success messages are emitted only after the
source transaction commits.

### Local integration coverage

The reconciliation tests use synthetic certificates and temporary directories
with real PostgreSQL transactions and advisory locks. Run the focused checks
with the isolated PostgreSQL/Consul services described in
[container validation](container-publishing.md):

```console
ruby bin/rails db:prepare
ruby bin/rails test test/services/filesystem_reconciliation_test.rb test/services/filesystem_reconciliation_concurrency_test.rb test/integration/filesystem_reconciliation_test.rb
```

Coverage includes two-pass cleanup, inaccessible and readable-empty sources,
partial subtree failures, restoration, source removal/readdition, identical
certificates across areas, late scan changes, transaction rollback, concurrent
indexers and competing administrator approvals. HTTP tests verify CA cache/Hiera
invalidation and rebuilding, overview/detail routes, public exports, Zabbix
inventory and retained audit history after cleanup. I/O and permission failures
are injected at filesystem calls; these tests do not exercise a real NFS server.
Concurrency tests use separate database sessions and wait for the actual
PostgreSQL advisory lock contention before continuing either scan.
