#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
test_count=0

for test_script in "$script_dir"/test_*.sh; do
    [[ -f "$test_script" ]] || continue
    test_count=$((test_count + 1))
    printf '\n==> %s\n' "${test_script##*/}"
    bash "$test_script"
done

(( test_count > 0 )) || {
    printf 'No review-pr tests found.\n' >&2
    exit 1
}

printf '\nAll %s review-pr test files passed.\n' "$test_count"

