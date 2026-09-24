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
