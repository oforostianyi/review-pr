#!/usr/bin/env bash
# The release dry run must complete without any real agent and leave a
# machine-readable checklist that names no private path.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

test_root=$(portable_mktemp_dir review-pr-dry-run)
trap 'rm -rf -- "$test_root"' EXIT

package_version=$(sed -n '1p' "$repo_root/VERSION")
fake_bin="$test_root/bin"
mkdir -p -- "$fake_bin"
ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
for hosted_command in claude codex; do
    printf '#!/bin/sh\nexit 0\n' >"$fake_bin/$hosted_command"
    chmod 0755 "$fake_bin/$hosted_command"
done

checklist="$test_root/out dir/release-dry-run.json"
scoped_tmp="$test_root/tmp"
mkdir -p -- "$scoped_tmp"
TMPDIR=$scoped_tmp PATH="$fake_bin:$PATH" bash "$repo_root/packaging/release-dry-run.sh" --output "$checklist" \
    >"$test_root/dry-run.txt" 2>"$test_root/dry-run.err" \
    || fail "release dry run failed: $(cat "$test_root/dry-run.txt" "$test_root/dry-run.err")"

assert_file_exists "$checklist" 'the dry run writes the checklist where requested'
assert_eq 'true' "$(jq -r '.passed' "$checklist")" 'a dry run without agents passes'
assert_eq "$package_version" "$(jq -r '.review_pr_version' "$checklist")" 'the checklist records the package version'
assert_eq 'skipped' "$(jq -r '.steps[] | select(.step == "contract-test") | .status' "$checklist")" \
    'the contract test is recorded as skipped when no agent is given'
for step in build-package verify-checksum verify-manifest extract-archive clean-install installed-version show-config uninstall uninstall-preserves-config uninstall-purge purge-removes-config; do
    assert_eq 'passed' "$(jq -r --arg step "$step" '.steps[] | select(.step == $step) | .status' "$checklist")" \
        "the ${step} step passes"
done
assert_eq "review-pr ${package_version}" "$(jq -r '.steps[] | select(.step == "installed-version") | .detail' "$checklist")" \
    'the checklist records the version reported by the installed launcher'
assert_false 'the checklist names no temporary or home directory' \
    grep -Eq "$test_root|$HOME|/tmp/|/private/|/var/folders/" "$checklist"
assert_file_contains "$test_root/dry-run.txt" "Release dry run passed for review-pr ${package_version}" \
    'the dry run announces success'
assert_false 'the dry run leaves no temporary directory behind' \
    bash -c 'ls -d "$1"/review-pr-dry-run.* 2>/dev/null | grep -q .' _ "$scoped_tmp"

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
