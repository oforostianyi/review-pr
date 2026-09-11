#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

audit="$repo_root/packaging/private-data-audit.sh"
test_root=$(portable_mktemp_dir review-pr-private-audit)
trap 'rm -rf -- "$test_root"' EXIT

assert_true 'the tracked repository contains no private paths or company identifiers' \
    "$audit" --root "$repo_root"

fixture_repo="$test_root/repo"
mkdir -p -- "$fixture_repo/docs"
git -C "$fixture_repo" init --quiet
printf '%s\n' '# Clean' 'See /Users/example/Work/review for the layout.' >"$fixture_repo/docs/clean.md"
git -C "$fixture_repo" add docs/clean.md
assert_true 'documented example paths are allowlisted' \
    "$audit" --root "$fixture_repo"

printf '%s\n' 'checkout: /home/someone/Work/Company/Review' >"$fixture_repo/docs/leak.md"
git -C "$fixture_repo" add docs/leak.md
leak_output="$test_root/leak.txt"
if "$audit" --root "$fixture_repo" >"$leak_output" 2>&1; then
    fail 'a tracked personal home path must fail the audit'
fi
pass 'a tracked personal home path fails the audit'
assert_file_contains "$leak_output" 'docs/leak.md:1' 'the audit names the offending file and line'

printf '%s\n' 'token = "ghp_0123456789abcdef0123456789abcdef0123"' >"$fixture_repo/docs/leak.md"
git -C "$fixture_repo" add docs/leak.md
assert_false 'a credential-like value fails the audit' \
    "$audit" --root "$fixture_repo"

printf '%s\n' 'ip: 192.168.10.20' >"$fixture_repo/docs/leak.md"
git -C "$fixture_repo" add docs/leak.md
assert_false 'a private network address fails the audit' \
    "$audit" --root "$fixture_repo"

printf '%s\n' 'This example is fine.' >"$fixture_repo/docs/leak.md"
printf '%s\n' 'untracked: /home/someone/private' >"$fixture_repo/docs/untracked.md"
git -C "$fixture_repo" add docs/leak.md
assert_true 'untracked files are not scanned' \
    "$audit" --root "$fixture_repo"

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
