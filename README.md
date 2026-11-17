# Lecture 11: Cloud Storage

This starter runs independently of earlier labs. Use Docker Compose and Bash (on Windows, use WSL). The commands below are the setup and command reference; follow the lecture page for the experiments and discussion.

The supplied Silo image is a local S3-compatible course fixture. All records and credentials are synthetic. The containers publish no host ports and require no cloud account. The AWS CLI service always uses the local object-store endpoint.

## Files

| File | Purpose |
| --- | --- |
| `scripts/compare.sh` | Your one editing task: compare two SHA-256 values. |
| `scripts/check.sh` | Checks for that function. |
| `verify.sh` | Supplied report lookup, exact-version download and checksum calculation. |
| `lab.sh` | Supplied shell helpers. |
| `fixtures/validations-v1.jsonl` | Three validation records from 20 November 2026 UTC. |
| `fixtures/validations-v2.jsonl` | The same three records plus one late-arriving record for that day. |
| `database/setup.sql`, `compose.yaml`, `aws-config` | Catalogue and local services. |
| `docs/evidence.md` | Your predictions, output and decisions. |

Keep the two fixture files unchanged after calculating their checksums. Each JSON record occupies one newline-terminated line. `row_count` counts those lines.

## Start the lab

Run from this folder in a Bash terminal:

```bash
source ./lab.sh
mkdir -p receipts downloads
lab_compose up -d postgres object-store
lab_compose ps
```

Wait until PostgreSQL is healthy. Check the object-store connection:

```bash
s3 s3api list-buckets
```

If startup is still in progress, wait briefly and repeat that command. It must succeed before continuing. Create the bucket once, then enable and inspect versioning:

```bash
s3 s3api create-bucket --bucket "$LAB_BUCKET"
s3 s3api put-bucket-versioning --bucket "$LAB_BUCKET" \
  --versioning-configuration Status=Enabled
s3 s3api get-bucket-versioning --bucket "$LAB_BUCKET"
```

The result must show `"Status": "Enabled"`. If you are resuming and the bucket already exists, use `head-bucket` to check it instead of creating another one:

```bash
s3 s3api head-bucket --bucket "$LAB_BUCKET"
```

Keep using the same terminal. In a new terminal, run `source ./lab.sh` again. The receipt files below let you recover version IDs after closing a terminal.

Run each publication sequence once. When resuming, reuse its saved checksum and version receipt instead of recalculating the expectation or uploading again.

## 1. Save the original report input

Calculate and save the expected checksum **before** uploading:

```bash
hash_file fixtures/validations-v1.jsonl > receipts/v1.sha256
row_count fixtures/validations-v1.jsonl
s3 s3api put-object --bucket "$LAB_BUCKET" --key "$LAB_KEY" \
  --body fixtures/validations-v1.jsonl --content-type application/x-ndjson \
  --query VersionId --output text > receipts/v1.version
```

Stop if a command fails. `row_count` must print `3`. `v1.version` must contain a version ID, not an empty value, `None` or `null`.

Download the recorded version and compare checksums:

```bash
s3 s3api get-object --bucket "$LAB_BUCKET" --key "$LAB_KEY" \
  --version-id "$(cat receipts/v1.version)" downloads/original.jsonl
cat receipts/v1.sha256
hash_file downloads/original.jsonl
row_count downloads/original.jsonl
```

Once the hash and row count match, record the original report input:

```bash
save_report R-001 "$(cat receipts/v1.version)" "$(cat receipts/v1.sha256)" 3
show_reports
```

## 2. Upload the corrected input at the same key

```bash
hash_file fixtures/validations-v2.jsonl > receipts/v2.sha256
row_count fixtures/validations-v2.jsonl
s3 s3api put-object --bucket "$LAB_BUCKET" --key "$LAB_KEY" \
  --body fixtures/validations-v2.jsonl --content-type application/x-ndjson \
  --query VersionId --output text > receipts/v2.version
s3 s3api get-object --bucket "$LAB_BUCKET" --key "$LAB_KEY" downloads/latest.jsonl
s3 s3api get-object --bucket "$LAB_BUCKET" --key "$LAB_KEY" \
  --version-id "$(cat receipts/v1.version)" downloads/original-again.jsonl
hash_file downloads/latest.jsonl
row_count downloads/latest.jsonl
hash_file downloads/original-again.jsonl
row_count downloads/original-again.jsonl
```

The corrected fixture has `4` records. Keep both version receipts. Do not save `R-002` yet: the next experiment starts at this interruption point.

## 3. Resume after upload, before catalogue save

Inspect the two stores:

```bash
show_reports
s3 s3api list-object-versions --bucket "$LAB_BUCKET" --prefix "$LAB_KEY" \
  > receipts/before-recovery.json
cat receipts/before-recovery.json
```

Recover using the existing upload receipt. There is no new PUT in this sequence:

```bash
s3 s3api get-object --bucket "$LAB_BUCKET" --key "$LAB_KEY" \
  --version-id "$(cat receipts/v2.version)" downloads/recovered.jsonl
cat receipts/v2.sha256
hash_file downloads/recovered.jsonl
row_count downloads/recovered.jsonl
```

Only after the saved expected hash and the four-record count agree:

```bash
save_report R-002 "$(cat receipts/v2.version)" "$(cat receipts/v2.sha256)" 4 R-001
show_reports
s3 s3api list-object-versions --bucket "$LAB_BUCKET" --prefix "$LAB_KEY" \
  > receipts/after-recovery.json
cat receipts/after-recovery.json
```

You can repeat that identical `save_report` command. It accepts an existing matching row, but rejects different metadata under the same report ID. It never updates an existing report's expected hash or version. Compare the version lists before and after recovery.

## 4. Complete and check verification

Edit only `compare_checksum(actual, expected)` in `scripts/compare.sh`. It receives the calculated hash first and the catalogue's expected hash second. Its contract is in that file.

In Bash, an early return can handle one invalid case:

```bash
if [[ -z "$actual" ]]; then
    printf 'InvalidInput\n'
    return 2
fi
```

You still need to validate the other input and the full checksum format before deciding whether valid values match.

```bash
bash scripts/check.sh
bash verify.sh R-001
bash verify.sh R-002
```

Before implementation the checks fail with `NotImplemented`. A completed function should pass all checks; both registered reports should verify as `Matches`.

Compare the corrected file directly with the original expectation:

```bash
source scripts/compare.sh
compare_checksum "$(hash_file fixtures/validations-v2.jsonl)" "$(cat receipts/v1.sha256)"
echo "$?"
```

Expect `Mismatch` and exit status `1`. Try an unknown report:

```bash
bash verify.sh NEVER-SAVED
echo "$?"
```

Then stop only the object store. The CLI has no service dependency that would restart it:

```bash
lab_compose stop object-store
bash verify.sh R-001
echo "$?"
lab_compose start object-store
```

The unavailable store produces `ReadFailed` with a nonzero exit status, never `Mismatch` or `Matches`. Wait for `s3 s3api list-buckets` to succeed after restarting, then verify again.

`verify.sh` only reads the catalogue. It requests the stored version ID, downloads the object, hashes its bytes and calls your function. It does not alter an expectation to make a check pass.

## Helper reference

| Command | Result |
| --- | --- |
| `s3 s3api ...` | AWS CLI against the fixed local endpoint. |
| `sql` | Runs SQL from stdin; `psql` options such as `-c` and `-v` are accepted. |
| `hash_file RELATIVE_PATH` | SHA-256 of a file inside this folder. |
| `row_count RELATIVE_PATH` | Number of newline-terminated lines. |
| `save_report ID VERSION SHA256 ROW_COUNT [SUPERSEDES]` | Saves a verified report input or accepts the identical existing entry. |
| `show_reports` | Lists catalogue rows. |
| `bash verify.sh REPORT_ID` | Checks that report's exact stored version against its recorded hash. |

Verifier results: `Matches` (0), `Mismatch` (1), `InvalidInput` (2), `UnknownReport` (3), `CatalogueReadFailed` (4), `ReadFailed` (5), `LocalReadFailed` (6). The unfinished function returns `NotImplemented` (7).

## Stop or start again

```bash
lab_compose stop
```

Start later with `lab_compose up -d postgres object-store`. The named volumes preserve both stores. Use the existing receipt files and catalogue rows when resuming. Repeating a PUT creates another object version, even when its bytes are identical.
