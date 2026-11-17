#!/usr/bin/env bash

# Complete this function. Both arguments must be 64 lowercase hexadecimal characters.
# Print exactly one result and return its exit status:
#   Matches     0  Both inputs are valid and equal.
#   Mismatch    1  Both inputs are valid and different.
#   InvalidInput 2 Either input is missing, empty or not a valid SHA-256 hex string.
# Do not read files, call S3, or change the expected checksum here.
compare_checksum() {
    local actual="${1-}" expected="${2-}"
    # TODO: validate both inputs, then compare them.
    printf 'NotImplemented\n'
    return 7
}
