#!/usr/bin/env bash
# Source this file: source ./lab.sh

LAB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LAB_BUCKET=mobility-archive-lab
LAB_KEY=validation-exports/2026-11-20/validations.jsonl

lab_compose() {
    docker compose --project-directory "$LAB_ROOT" -f "$LAB_ROOT/compose.yaml" "$@"
}

s3() {
    lab_compose run --rm -T aws "$@"
}

# SQL is read from stdin; additional arguments are forwarded to psql.
sql() {
    lab_compose exec -T postgres psql -X -U mobility -d mobility_l11 \
        -v ON_ERROR_STOP=1 "$@"
}

lab_path() {
    case "${1-}" in
        ''|/*|..|../*|*/../*|*/..) printf 'Use a path inside the lab folder.\n' >&2; return 2 ;;
    esac
    printf '/work/%s\n' "$1"
}

hash_file() {
    local path result
    path="$(lab_path "${1-}")" || return
    result="$(lab_compose exec -T postgres sha256sum -- "$path")" || return
    printf '%s\n' "${result%% *}"
}

row_count() {
    local path result count rest
    path="$(lab_path "${1-}")" || return
    result="$(lab_compose exec -T postgres wc -l -- "$path")" || return
    read -r count rest <<< "$result"
    printf '%s\n' "$count"
}

# save_report REPORT_ID VERSION_ID SHA256 ROW_COUNT [SUPERSEDES]
# A repeated, identical save is accepted. Existing report metadata is never changed.
save_report() {
    if (( $# < 4 || $# > 5 )); then
        printf 'Usage: save_report REPORT_ID VERSION_ID SHA256 ROW_COUNT [SUPERSEDES]\n' >&2
        return 2
    fi
    local result
    result="$(sql -qAt \
        -v report_id="$1" -v version_id="$2" -v sha256="$3" \
        -v row_count="$4" -v supersedes="${5-}" \
        -v bucket="$LAB_BUCKET" -v object_key="$LAB_KEY" <<'SQL'
INSERT INTO reports (report_id, bucket_name, object_key, version_id, sha256, row_count, supersedes)
VALUES (:'report_id', :'bucket', :'object_key', :'version_id', :'sha256',
        :'row_count'::integer, NULLIF(:'supersedes', ''))
ON CONFLICT (report_id) DO NOTHING;

SELECT CASE WHEN bucket_name = :'bucket'
                 AND object_key = :'object_key'
                 AND version_id = :'version_id'
                 AND sha256 = :'sha256'
                 AND row_count = :'row_count'::integer
                 AND supersedes IS NOT DISTINCT FROM NULLIF(:'supersedes', '')
            THEN 'Saved' ELSE 'ReportConflict' END
FROM reports WHERE report_id = :'report_id';
SQL
    )" || { printf 'CatalogueWriteFailed\n' >&2; return 4; }
    if [[ "$result" != Saved ]]; then
        printf 'ReportConflict: existing report metadata was preserved.\n' >&2
        return 3
    fi
    printf 'Saved %s\n' "$1"
}

show_reports() {
    sql -c 'SELECT report_id, row_count, supersedes, version_id, sha256 FROM reports ORDER BY report_id;'
}
