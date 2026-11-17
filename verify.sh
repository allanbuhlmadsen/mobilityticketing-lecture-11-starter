#!/usr/bin/env bash
set -u
set -o pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lab.sh"
source "$LAB_ROOT/scripts/compare.sh"

if (( $# != 1 )); then
    printf 'Usage: bash verify.sh REPORT_ID\n' >&2
    exit 2
fi

record="$(sql -qAt -F $'\t' -v report_id="$1" <<'SQL'
SELECT bucket_name, object_key, version_id, sha256
FROM reports WHERE report_id = :'report_id';
SQL
)" || { printf 'CatalogueReadFailed\n'; exit 4; }

if [[ -z "$record" ]]; then
    printf 'UnknownReport\n'
    exit 3
fi

IFS=$'\t' read -r bucket key version expected <<< "$record"
mkdir -p "$LAB_ROOT/downloads" || { printf 'LocalReadFailed\n'; exit 6; }
temporary="$(mktemp -d "$LAB_ROOT/downloads/verify.XXXXXX")" \
    || { printf 'LocalReadFailed\n'; exit 6; }
trap 'rm -rf -- "$temporary"' EXIT
relative="downloads/${temporary##*/}/object.jsonl"

if ! s3 s3api get-object --bucket "$bucket" --key "$key" \
    --version-id "$version" "$relative" > "$temporary/receipt.json"; then
    printf 'ReadFailed\n'
    exit 5
fi

actual="$(hash_file "$relative")" || { printf 'LocalReadFailed\n'; exit 6; }
if result="$(compare_checksum "$actual" "$expected")"; then
    outcome=0
else
    outcome=$?
fi
printf '%s\n' "$result"
exit "$outcome"
