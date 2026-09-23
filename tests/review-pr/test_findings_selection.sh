#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Tests assign the sourced orchestrator's globals.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

suite_root=$(portable_mktemp_dir review-pr-findings-selection)
trap 'rm -rf -- "$suite_root"' EXIT

root="$suite_root/reviews"
mkdir -p -- "$root/123-a/work/20260920-100000-CEST" "$root/123-a/work/20260921-100000-CEST"

# A re-synthesis is named after the run it re-synthesised, so its file sorts by
# that older source run. Ordering the candidates as text therefore handed the
# fixing agent a report that had been superseded days earlier.
old_run="$root/123-a/work/20260920-100000-CEST/123-a-20260920-100000-CEST"
new_run="$root/123-a/work/20260921-100000-CEST/123-a-20260921-100000-CEST"
rerun="${old_run}-final-rerun-20260923-090000-CEST"

printf '{"findings":[]}\n' >"${new_run}-final-findings.json"
printf '{"findings":[]}\n' >"${rerun}-findings.json"
jq -n '{created_at: "2026-09-21T10:05:00+0200"}' >"${new_run}-manifest.json"
jq -n '{created_at: "2026-09-23T09:05:00+0200"}' >"${rerun}-manifest.json"

assert_eq "${rerun}-findings.json" "$(select_final_findings_artifact "$root/123-a" 123 '')" \
    'the newest synthesis wins even though it is named after an older run'

# Runs made before manifests recorded an instant still have to be ordered.
rm -- "${new_run}-manifest.json" "${rerun}-manifest.json"
assert_eq "${rerun}-findings.json" "$(select_final_findings_artifact "$root/123-a" 123 '')" \
    'without a recorded instant the produced-at stamp in the name decides'

assert_eq "${new_run}-final-findings.json" "$(select_final_findings_artifact "$root/123-a" 123 20260921-100000-CEST)" \
    'an explicit run selector still pins the run it names'
assert_eq "${rerun}-findings.json" "$(select_final_findings_artifact "$root/123-a" 123 20260920-100000-CEST)" \
    'and selecting the older run finds the re-synthesis made from it'

assert_eq '' "$(select_final_findings_artifact "$root/123-a" 999 '')" \
    'another pull request selects nothing rather than someone else report'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
