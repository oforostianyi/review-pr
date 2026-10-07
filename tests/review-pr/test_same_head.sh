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

suite_root=$(portable_mktemp_dir review-pr-same-head)
trap 'rm -rf -- "$suite_root"' EXIT

# The methodology hash: what each agent is told to review with.
CONFIG_DIRECTORY="$suite_root/config"
CONFIG_FILE="$CONFIG_DIRECTORY/config.json"
mkdir -p -- "$CONFIG_DIRECTORY/skills/claude/php-code-review/checklists"
printf '{"prompts": {"primary": ["Review it."]}}\n' >"$CONFIG_FILE"
printf 'Review methodology.\n' >"$CONFIG_DIRECTORY/skills/claude/php-code-review/SKILL.md"
printf 'ADR rules.\n' >"$CONFIG_DIRECTORY/skills/claude/php-code-review/checklists/adr.md"
printf 'Test rules.\n' >"$CONFIG_DIRECTORY/skills/claude/php-code-review/checklists/tests.md"
printf 'A backup is not embedded.\n' >"$CONFIG_DIRECTORY/skills/claude/php-code-review/checklists/adr.md.bak-20261003"
declare -A AGENT_TYPES=([claude]=claude [codex]=codex)
declare -A AGENT_SKILLS=([claude]=php-code-review [codex]=php-code-review)
REVIEW_AGENTS=(claude codex)
FINAL_SYNTHESIZER=claude
FALLBACK_SYNTHESIZER=""

compute_review_methodology
first=$REVIEW_METHODOLOGY_HASH
assert_true 'the methodology hash is a sha256' grep -Eq '^[0-9a-f]{64}$' <<<"$first"
REVIEW_AGENTS=(codex claude)
compute_review_methodology
assert_eq "$first" "$REVIEW_METHODOLOGY_HASH" 'the order the agents are listed in does not change it'
printf 'Another backup.\n' >"$CONFIG_DIRECTORY/skills/claude/php-code-review/checklists/tests.md.bak"
compute_review_methodology
assert_eq "$first" "$REVIEW_METHODOLOGY_HASH" 'nor does a backup file next to the checklists, which is never embedded'
printf 'ADR rules, updated from CONTRIBUTING.md.\n' >"$CONFIG_DIRECTORY/skills/claude/php-code-review/checklists/adr.md"
compute_review_methodology
changed=$REVIEW_METHODOLOGY_HASH
assert_false 'a changed checklist changes it (adr.md on 2026-10-03)' test "$first" = "$changed"
printf '{"prompts": {"primary": ["Review it carefully."]}}\n' >"$CONFIG_FILE"
compute_review_methodology
assert_false 'and so does a changed configured prompt' test "$changed" = "$REVIEW_METHODOLOGY_HASH"
current=$REVIEW_METHODOLOGY_HASH

# The guard on a new full run.
PR_NUMBER=123
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BASE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REPORT_DIR="$suite_root/reports/123-fix"
write_run() {
    local timestamp=$1 head=$2 base=$3 pipeline=$4 methodology=$5
    mkdir -p -- "$REPORT_DIR/work/$timestamp"
    jq -n --arg timestamp "$timestamp" --arg head "$head" --arg base "$base" --arg pipeline "$pipeline" \
        --arg methodology "$methodology" --argjson pr "$PR_NUMBER" \
        '{run_type: "full", pr_number: $pr, timestamp: $timestamp, created_at: ($timestamp[0:4] + "-10-02T22:39:00+0200"),
          head_sha: $head, base_sha: $base, status: {pipeline: $pipeline}}
         + (if $methodology == "" then {} else {methodology: {hash: $methodology}} end)' \
        >"$REPORT_DIR/work/$timestamp/123-fix-$timestamp-manifest.json"
}
guard() { ( refuse_same_head_review ) 2>&1; }

assert_true 'a PR never reviewed before goes ahead' refuse_same_head_review
write_run 20261002-223856-CEST "$HEAD_SHA" "$BASE_SHA" complete "$current"
set +e
refusal=$(guard); refusal_status=$?
set -e
assert_eq 1 "$refusal_status" 'the same head, base and methodology as the last complete run is refused'
assert_true 'and the refusal names the run and how to ask for the repeat' \
    grep -q 'run 20261002-223856-CEST).*--same-head' <<<"$refusal"
SAME_HEAD_ALLOWED=true
assert_true '--same-head reviews it again on purpose' refuse_same_head_review
SAME_HEAD_ALLOWED=false
HEAD_SHA=1111111111111111111111111111111111111111
assert_true 'a new head goes ahead' refuse_same_head_review
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BASE_SHA=2222222222222222222222222222222222222222
assert_true 'and so does a new base' refuse_same_head_review
BASE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REVIEW_METHODOLOGY_HASH=$first
assert_true 'and a changed methodology, which says why' \
    grep -q 'methodology has changed since' <<<"$(guard)"
REVIEW_METHODOLOGY_HASH=$current
rm -rf -- "$REPORT_DIR"
write_run 20261002-223856-CEST "$HEAD_SHA" "$BASE_SHA" complete ''
assert_true 'a run made before the methodology was recorded does not block the review' \
    grep -q 'recorded no methodology; reviewing again' <<<"$(guard)"
rm -rf -- "$REPORT_DIR"
write_run 20261002-223856-CEST "$HEAD_SHA" "$BASE_SHA" failed "$current"
assert_true 'nor does a run that did not complete' refuse_same_head_review

# What the fix-list now carries about the review behind it.
HEAD_REF=fix/FIX-123
BASE_REF=master
RERUN_FINAL=false
timed_phase primary true
assert_eq 'number' "$(phase_seconds_json | jq -r '.primary | type')" 'a phase that ran has its seconds'
assert_eq 'null' "$(phase_seconds_json | jq -r '.cross')" 'and one this process did not run is null'
PHASE_STARTED[final]=$(( $(date +%s) - 5 ))
assert_true 'a phase still running is counted up to now' test "$(phase_seconds_json | jq -r '.final')" -ge 5
review=$(current_review_json)
assert_eq "$HEAD_SHA|$BASE_SHA|$current|full" \
    "$(jq -r '"\(.head_sha)|\(.base_sha)|\(.methodology_hash)|\(.run_type)"' <<<"$review")" \
    'the review object names the head, base, methodology and kind of run'
canonical="$suite_root/final-findings.json"
jq -n '{findings: [{source_id: "F-1", classification: "CONFIRMED", severity: "P2", category: "correctness",
    anchor: {kind: "changed-line", file: "src/A.php", start: 1, "end": 1}, title: "T", claim: "C",
    failure_scenario: "S", recommendation: "R", verification_limitations: []}]}' >"$canonical"
assert_eq "$HEAD_SHA" "$(render_findings_export "$canonical" 20261002-223856-CEST confirmed "$review" | jq -r '.review.head_sha')" \
    'the fix-list carries the head it was made from'
assert_eq 'null' "$(render_findings_export "$canonical" 20261002-223856-CEST confirmed | jq -r '.review')" \
    'and a review object nobody passed is null rather than invented'
manifest=$(find "$REPORT_DIR/work" -name '*-manifest.json' | head -n 1)
assert_eq "$HEAD_SHA|$current" "$(manifest_review_json "$manifest" | jq -r '"\(.head_sha)|\(.methodology_hash)"')" \
    'review-pr findings reads the same fields back from the run manifest'

# A head that adds nothing to its base: nothing to review, so no reviewer starts.
# Tools 29204 was stacked on a collective branch that had already merged it.
REVIEW_REPO="$suite_root/repository"
git init -q "$REVIEW_REPO"
git -C "$REVIEW_REPO" -c user.name=Test -c user.email=test@example.test commit -q --allow-empty -m base
printf 'change\n' >"$REVIEW_REPO/file.txt"
git -C "$REVIEW_REPO" add file.txt
git -C "$REVIEW_REPO" -c user.name=Test -c user.email=test@example.test commit -q -m change
feature_head=$(git -C "$REVIEW_REPO" rev-parse HEAD)
git -C "$REVIEW_REPO" -c user.name=Test -c user.email=test@example.test commit -q --allow-empty -m 'collective merged it'
collective=$(git -C "$REVIEW_REPO" rev-parse HEAD)
base_before=$(git -C "$REVIEW_REPO" rev-parse HEAD~2)
PR_NUMBER=123 BASE_REF=collective HEAD_REF=fix/FIX-123
HEAD_SHA=$feature_head BASE_SHA=$base_before
assert_true 'a head with changes against its base goes ahead' refuse_empty_diff_review
BASE_SHA=$collective
set +e
empty=$( ( refuse_empty_diff_review ) 2>&1 ); empty_status=$?
set -e
assert_eq 1 "$empty_status" 'a head already merged into its base is refused'
assert_true 'and the refusal says the head is already in the base branch' \
    grep -q 'Nothing to review in PR #123: its head .* is already in collective' <<<"$empty"
git -C "$REVIEW_REPO" checkout -q -b reverted "$feature_head"
git -C "$REVIEW_REPO" -c user.name=Test -c user.email=test@example.test revert --no-edit HEAD >/dev/null
HEAD_SHA=$(git -C "$REVIEW_REPO" rev-parse HEAD) BASE_SHA=$base_before
set +e
empty=$( ( refuse_empty_diff_review ) 2>&1 ); empty_status=$?
set -e
assert_eq 1 "$empty_status" 'a head whose commits cancel out is refused too'
assert_true 'and the refusal says the range has no changes' grep -q 'has no changes' <<<"$empty"

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
