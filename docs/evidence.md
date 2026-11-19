# Cloud Storage: evidence

## Project boundaries

```
CLI   src/MobilityTicketing.Reports/Program.cs
  |   parses the command, reads the file with File.ReadAllBytesAsync,
  |   builds LocalReportServices and takes its Workflow property
  v
ReportWorkflow   (Application project)
  |
  +-- PublishAsync(id, bytes, supersedes)  =  StageAsync then RecoverAsync
       |
       +--> StageAsync(id, bytes)
       |      1. SHA-256 and newline count, both over the same byte[]
       |      2. IUploadReceipts.Reserve(id) ........... receipts/<id>.json created empty
       |      3. IReportObjectStore.UploadAsync(dest)... PUT the bytes  ==> versionId
       |
       |         ======== GAP A: the PUT succeeded, nothing records which version ========
       |
       |      4. IUploadReceipts.WriteAsync(input) ..... receipts/<id>.json now holds
       |                                                 versionId, sha256, rowCount
       |      returns versionId
       |
       |         ======== GAP B: the version is recorded locally, not published ========
       |
       +--> RecoverAsync(id, supersedes)
              5. IUploadReceipts.ReadAsync(id) ......... read the staged receipt
              6. CheckAsync(input)
                   IReportObjectStore.ReadVersionAsync() GET that exact versionId
                   measure the returned bytes, compare both values with the receipt
              7. only when CheckAsync returns Matches:
                   IReportCatalogue.SaveAsync(input, supersedes)
                     INSERT INTO reports ... ON CONFLICT (report_id) DO NOTHING
                     COMMIT   <=== the report is published at this instant
              returns the report ID

VerifyAsync(id)   8. IReportCatalogue.FindAsync(id) ..... resolve the ID to bucket,
                                                          key and version
                  9. CheckAsync(that row) ............... GET that exact version
```

**Interface owners.** All three interfaces — `IReportObjectStore`, `IReportCatalogue` and `IUploadReceipts` — are declared in `Ports.cs` in the **Application** project, together with `ExportLocation`, `ReportInput`, `Verification` and the three exception types. Application owns the contracts and the workflow and references nothing. The dependency arrow points inwards: Infrastructure depends on Application, never the reverse.

**Adapter implementations.** Each interface has exactly one `internal sealed` implementation in the **Infrastructure** project: `S3ReportObjectStore` wraps `IAmazonS3`, `ReportCatalogue` wraps an `NpgsqlDataSource`, and `UploadReceipts` writes JSON files in the local `receipts` folder. `LocalReportServices` is the only place where concrete types meet the workflow; it constructs all three adapters, fixes the destination to bucket `mobility-archive-lab` and key `validation-exports/2026-11-20/validations.jsonl`, and hands the finished `ReportWorkflow` to the CLI.

**The catalogue commit.** `ReportCatalogue.InsertAsync` opens its own connection, begins a transaction, inserts the row and calls `CommitAsync`. That commit is the moment the report becomes published. Everything before it — the object in the bucket, the receipt on disk — is preparation that no reader can resolve by report ID.

**Gap A, between the upload and the receipt**, is the one the task asks to mark. The PUT has created a new object version and returned its version ID, but nothing durable records that ID yet. A crash here leaves a version in the bucket that no report refers to and that no receipt names; the only trace is the empty reservation file from step 2, which is why an empty receipt means the upload outcome has to be investigated rather than retried blindly.

**Gap B, between the receipt and the commit**, is the one the lab deliberately reproduces with the separate `stage` command. Here the version ID is written down, so recovery needs no second PUT: it reads the receipt, verifies that exact version and commits the catalogue row.

## Experiments

| Scenario | Prediction | Command, result and exit status | What changed in the catalogue and bucket? |
| --- | --- | --- | --- |
| Publish the original | Stage and recover in one go: the receipt is reserved and written, the PUT returns a version, the bytes read back match the measurements, and the catalogue row commits | `report publish R-001 fixtures/validations-v1.jsonl` → `Saved R-001`, exit 0 | First object version `390ca988-e853-4c49-81bd-2a92fea3820b`, 303 bytes, on key `validation-exports/2026-11-20/validations.jsonl`. One catalogue row `R-001`, row_count 3, `supersedes` empty, sha256 `3a41a3be…ba4a2f`. `receipts/R-001.json` left on disk |
| Interrupt after staging a correction | `stage` stops after the receipt, so a second version exists at the same key with no catalogue row, and the report ID cannot be resolved | `report stage R-002 fixtures/validations-v2.jsonl` → `77ac716d-abf1-4323-91c2-0cde7fe15532`, exit 0. `report verify R-002` → `UnknownReport`, exit 3 | Second version `77ac716d…`, 404 bytes, same key, now `IsLatest: true`. Catalogue unchanged, still only `R-001`. `receipts/R-002.json` holds that version with sha256 `545370b3…` and row_count 4 |
| Recover with a mismatched receipt | `CheckAsync` reads the recorded version and measures it; 64 zeros will not match the real checksum, so `RecoverAsync` throws before `SaveAsync` is reached | `Sha256` in `receipts/R-002.json` replaced with 64 zeros, then `report recover R-002 R-001` → `Recovery of R-002 stopped because verifying the staged version returned Mismatch. Nothing was written to the catalogue.`, exit 1 | Nothing. No catalogue row and no new object version. The receipt was restored from `receipts/R-002.json.bak` afterwards. Note that 64 zeros pass the receipt adapter's own `[0-9a-f]{64}` check, so the error is caught by the comparison against the bytes and not by a format test |
| Recover with a nonexistent predecessor | Verification matches this time, so `SaveAsync` is reached, and the foreign key on `supersedes` rejects the row | `report recover R-002 R-999` → `23503: insert or update on table "reports" violates foreign key constraint "reports_supersedes_fkey"`, exit 1. Npgsql withheld the `DETAIL` line by default | Nothing. The transaction rolled back, leaving one catalogue row and the same two object versions with unchanged `LastModified` timestamps |
| Recover and repeat recovery | Both attempts succeed. The second changes nothing, because the row it would write is identical to the row already there | `report recover R-002 R-001` → `Saved R-002`, exit 0. The identical command again → `Saved R-002`, exit 0 | Second catalogue row `R-002`, row_count 4, `supersedes` `R-001`, version `77ac716d…`. **No third object version**, and both timestamps unchanged: recovery reads, it never uploads |
| Verify the original after the correction | `R-001` still resolves to the older version, although the newer one is the current object at that key | `report verify R-001` → `Matches`, exit 0. `report verify R-002` → `Matches`, exit 0 | Nothing. Verification is read-only |
| Verify with object storage stopped | The catalogue still resolves the ID, but the GET cannot complete, so the result must be `ReadFailed` and not `Mismatch` | `lab_compose stop object-store`, then `report verify R-001` → `ReadFailed`, exit 5. After `lab_compose start object-store` and `s3 s3api head-bucket`, `report verify R-001` → `Matches`, exit 0 | Nothing. The same bytes were there throughout, which the second verification proves |
| Verify with PostgreSQL stopped | The report ID cannot be turned into a version at all, so the object store is never contacted and the failure is reported as a catalogue failure | `lab_compose stop postgres`, then `report verify R-001` → `CatalogueReadFailed`, exit 4. After `lab_compose start postgres` reached `(healthy)`, `report verify R-001` → `Matches`, exit 0 | Nothing. The object store was running and held both versions the whole time, and was never asked |

### What the two outages establish

**A failed read cannot tell you whether the bytes changed, because there are no bytes to look at.** With the object store stopped, the catalogue answered normally: `VerifyAsync` resolved `R-001` to its bucket, key and version and knew exactly what to fetch. The fetch is what did not complete, so `CheckAsync` had nothing to measure — not wrong bytes, not right bytes, none at all. `Mismatch` would be a claim about content: that the bytes were seen and are not the ones that were stored. Nothing supports that claim here. `ReadFailed` says only that the attempt did not get far enough to look, and the two call for opposite responses: one is an alarm about corrupted data, the other is an operational fault that clears by itself. Restarting the store and verifying again returned `Matches`, which shows the same bytes had been there throughout.

**The two outages produce different exit codes, and the difference shows the order of the dependencies.** With the object store down the failure came late: the catalogue had already turned the report ID into a version, and exit code 5 means the fetch of that known version failed. With PostgreSQL down the failure came at the very first step: `FindAsync` threw, `VerifyAsync` returned `CatalogueReadFailed` with exit code 4, and `CheckAsync` was never reached, so the object store was never contacted — even though it was running and holding both versions. The catalogue is the entrance. Without it a report ID is just a string, because only the catalogue knows which of the two versions at that one key belongs to `R-001`, and the object store cannot answer that question however available it happens to be.

## Version IDs and row counts

Both exports live at the same object key, `validation-exports/2026-11-20/validations.jsonl`, and are told apart only by their version IDs.

| Report | Version ID | Size | Rows | sha256 | IsLatest after both uploads |
| --- | --- | ---: | ---: | --- | --- |
| R-001, the original three-row export | `390ca988-e853-4c49-81bd-2a92fea3820b` | 303 bytes | 3 | `3a41a3be76217883a3790a0c8889e53278575188dd5b61cf85226e6210ba4a2f` | false |
| R-002, the corrected four-row export | `77ac716d-abf1-4323-91c2-0cde7fe15532` | 404 bytes | 4 | `545370b304ada29a502c2e9430fe20d36d62f5bf527729220e24bd7fb81c4641` | true |

The row count is the number of newline characters in the uploaded bytes, measured by the workflow from the same array it uploads, so the receipt describes exactly what was sent rather than a second reading of the file. The two sizes, 303 and 404 bytes, are an independent confirmation of which version is which.

**Why only the original report was in the catalogue at that point.** The second upload had completed: the bytes were in the bucket, the version existed, and it was the current object at that key. What had not happened was the catalogue write. `stage` stops deliberately after `IUploadReceipts.WriteAsync`, so `IReportCatalogue.SaveAsync` was never called and no row for `R-002` was committed. A report is published when its catalogue row commits, and nothing else makes it published. `report verify R-002` returned `UnknownReport` with exit code 3, having never contacted the object store: without a catalogue row there is no way from a report ID to a version, and at that moment the only thing recording `77ac716d…` was the local receipt.

This is also why `R-001` keeps working afterwards. The catalogue stores a bucket, a key **and** a version, not a key alone. Had it stored only the key, resolving `R-001` after the correction would have returned the four-row export, because that is what the key now points to.

## An additional check

The two identical recoveries above both succeeded, which raises the question of where the limit is. One further run answers it.

`report recover R-002` was run **without** a predecessor, after `R-002` had already been saved with `R-001` as its predecessor. Result: `ReportConflict`, exit 1, and `show_reports` showed the original row completely unchanged.

The whole workflow ran to the end before the conflict was found. The receipt was read, the recorded version was fetched, the bytes were measured, and `CheckAsync` returned `Matches`. Only at the insert did it emerge that the same report ID already stood with different contents. The supplied `ReportCatalogue.InsertAsync` inserts with `ON CONFLICT (report_id) DO NOTHING` and then compares all seven stored values against the ones it was about to write, with `supersedes IS NOT DISTINCT FROM $7` so that a null predecessor is compared as a value rather than being ignored. Null is not `R-001`, the rows differ, and the insert is refused with `InvalidOperationException("ReportConflict")` inside a transaction that then rolls back.

The rule this draws is narrow and worth stating exactly: repeating the **same** request is safe because the result would be the same row. Reusing the same report ID with **different** details is not a repeat at all, but a different request wearing the same name, and it is refused rather than allowed to overwrite what is already published.

## Ownership

| What | Where it belongs | Why there |
| --- | --- | --- |
| The original validation rows | PostgreSQL, as operational records | They are the operational truth that the export is generated from, and they are queried, corrected and constrained like any other operational data. The starter's `database/setup.sql` creates only the `reports` table, so these rows are not modelled in this lab; the lecture's component table places them in PostgreSQL |
| The export bytes | Object storage, one version per generated export | They are a large, immutable blob that is written once and read whole. A relational table is the wrong shape for that, and versioning at the same key is what allows two reports to refer to different bytes at one location |
| The report metadata | The `reports` table in PostgreSQL | Report ID, predecessor, expected checksum, row count, and the bucket, key and version that identify the export. These are small, related, and need constraints the object store cannot give: a primary key on the ID, a foreign key on `supersedes`, and `UNIQUE (bucket_name, object_key, version_id)` |
| The pending upload state | A local receipt, `receipts/<id>.json` | It belongs to one in-flight attempt and must survive the gap between the PUT and the catalogue commit. It is deliberately not in the catalogue: a row there would mean the report is published, which is exactly what has not happened yet |

**How an API receiving R-001 finds the three-row export after the four-row export became current.** This is `VerifyAsync` and it was measured. The ID goes to `IReportCatalogue.FindAsync`, which returns the stored bucket `mobility-archive-lab`, key `validation-exports/2026-11-20/validations.jsonl` and version `390ca988-e853-4c49-81bd-2a92fea3820b`. Those three values go to `IReportObjectStore.ReadVersionAsync`, which fetches that exact version rather than whatever is current at the key. The returned bytes are measured and compared with the stored checksum and row count, and `report verify R-001` returned `Matches` with exit code 0 while `77ac716d…` was the version marked `IsLatest`.

Two properties make that work, and removing either breaks it. The catalogue stores the version, not just the key. And versioning is enabled on the bucket, so the earlier bytes still exist after a second upload to the same key instead of being replaced.

## Safe retries

| Failure point | What might already exist | What the caller sees | What can safely be retried |
| --- | --- | --- | --- |
| The PUT fails | The reservation file, empty. The object version may or may not exist: an upload can fail after the bytes have landed | `ObjectStoreException` from the adapter, its message on standard error, exit 1 | Nothing automatically. A second `stage` for the same ID is refused by `Reserve`, because the file already exists, and that refusal is the intended behaviour. The empty receipt means the outcome is unknown and must be investigated — by listing the versions at the key — before another PUT is issued |
| The catalogue write fails, with a receipt present | The object version exists and the receipt names it. No catalogue row | `CatalogueException` with the PostgreSQL message, or `ReportConflict`, exit 1 | `recover` with the same report ID and the same predecessor. It reads the recorded version and issues no PUT. Measured: after `recover R-002 R-999` failed on the foreign key, `recover R-002 R-001` succeeded, and the bucket still held exactly two versions with unchanged timestamps |
| A crash before the receipt is written | The object version may exist, and nothing names it. Only the empty reservation file remains | Nothing. The process is gone | Not `stage`, which `Reserve` refuses. The empty receipt is the signal to look at the bucket: the version list for the key shows whether a version arrived, and the only way to tell which one it is, is by its timestamp and contents, because no record ties it to the report |

**Why an identical recovery can succeed twice.** The supplied `ReportCatalogue.InsertAsync` writes with `INSERT ... ON CONFLICT (report_id) DO NOTHING`. On the second run the insert matches nothing, so the code then asks whether the row already there is identical to the one it meant to write, comparing all seven values and treating a null predecessor as a value with `IS NOT DISTINCT FROM`. Identical means there is nothing to do, and the transaction commits having changed nothing. Running `recover R-002 R-001` twice therefore printed `Saved R-002` both times with exit code 0, and added no object version.

**Where that stops.** `recover R-002` without a predecessor, after `R-002` had been saved with `R-001`, returned `ReportConflict` with exit code 1 and left the stored row untouched. The comparison is what draws the line: a repeat of the same request is safe, and the same ID carrying different details is a different request that happens to reuse the name.

## Storage decision

This section answers the access and retention questions.

**Where to check the caller's right to read.** As early as the policy allows, and in every case **before** the object version is resolved into a fetch. If the rule depends only on the caller — a role, an operator, a tenant — the check belongs before the catalogue is touched at all, so an unauthorised request never reaches either store. If the rule depends on attributes of the report itself, the catalogue read is unavoidable, and the check then sits between `FindAsync` and `ReadVersionAsync`. What must not happen either way is that a refusal still hands back the version ID: that value is itself information, and a caller who can reach the object store could use it to fetch the bytes directly. In this codebase the check does not belong in `ReportWorkflow`. The Application project has no notion of a caller, and giving it one would make it depend on whatever carries identity in the host. It belongs in the layer that replaces `Program.cs` in an API version, around the call into the workflow.

**Which operations the application's storage identity needs.** Two, both scoped to the one key prefix the lab writes to: putting an object, which creates a new version, and reading a named version. The second is worth stating separately, because reading a specific version is not the same permission as reading whatever is current at the key, and this application never reads the current object — it always names a version. It needs nothing else. It never deletes an object, never deletes a version, never lists the bucket, and never changes the bucket's versioning configuration. Listing versions was done in this lab from the command line, by a human, not by the application.

**How a cleanup job would tell a pending upload from a referenced version.** By joining the bucket's version list against the catalogue on bucket, key and version. The `reports` table already carries `UNIQUE (bucket_name, object_key, version_id)`, so each published report names exactly one version and no two reports name the same one. A version in the bucket with no matching row is a candidate for removal; a version with a matching row is referenced and must stay. Two cautions follow from what was measured. A candidate may be a staged upload whose recovery has not run yet, so the job needs a grace period and should treat a local receipt naming that version as a reason to leave it alone. And the job must run with a different identity from the application, since the application needs no deletion rights at all.

**Why a lifecycle rule on noncurrent versions would be dangerous here.** `R-001` points at `390ca988…`, which has `IsLatest: false` — it became noncurrent the moment the correction was uploaded to the same key. A rule that expires noncurrent versions after some number of days would therefore delete precisely the versions that superseded reports depend on, and it would do so silently. The catalogue row for `R-001` would survive and keep claiming that the export exists. What a reader would get is the behaviour measured during the object-store outage: `verify` returns `ReadFailed` with exit code 5, because the fetch did not complete. The distinction matters here too — the report would not be reported as changed, only as unreadable, and the catalogue would give no hint that the bytes are gone for good rather than temporarily unreachable. Moving a version to a colder storage class is a different matter: the object still exists and can still be fetched, so a report that refers to it remains verifiable, at the cost of a slower or more expensive read.