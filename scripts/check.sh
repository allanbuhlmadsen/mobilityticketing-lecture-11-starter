#!/usr/bin/env bash
set -u
source "$(dirname -- "${BASH_SOURCE[0]}")/compare.sh"

passed=0
failed=0
one=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
last=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab
first=baaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

check() {
    local label="$1" wanted="$2" wanted_status="$3" actual="$4" expected="$5"
    local output status
    if output="$(compare_checksum "$actual" "$expected")"; then status=0; else status=$?; fi
    if [[ "$output" == "$wanted" && "$status" -eq "$wanted_status" ]]; then
        printf 'PASS %s\n' "$label"
        passed=$((passed + 1))
    else
        printf 'FAIL %s: expected %s (exit %s); got %s (exit %s)\n' \
            "$label" "$wanted" "$wanted_status" "$output" "$status"
        failed=$((failed + 1))
    fi
}

check 'same valid checksum' Matches 0 "$one" "$one"
check 'last character differs' Mismatch 1 "$last" "$one"
check 'first character differs' Mismatch 1 "$first" "$one"
check 'both empty' InvalidInput 2 '' ''
check 'empty actual' InvalidInput 2 '' "$one"
check 'empty expected' InvalidInput 2 "$one" ''
check 'too short' InvalidInput 2 "${one:1}" "$one"
check 'non-hex expected' InvalidInput 2 "$one" "${one:1}g"

printf '%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
