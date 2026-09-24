#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Tests assign the sourced orchestrator's globals and index its associative arrays.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

test_root=$(portable_mktemp_dir review-pr-validators)
trap 'rm -rf -- "$test_root"' EXIT

WORK_DIR=$test_root
REPORT_STEM=fixture
DASHBOARD_ACTIVE=true
REVIEW_AGENTS=(alpha beta)
AGENT_LABELS[alpha]=Alpha
AGENT_LABELS[beta]=Beta
FINALIZATION_LANGUAGE=EN
configure_finalization_language
build_review_matrix_table_header EN

FINAL_HEADER_TITLE='# Code Review: [PR #123](https://example.test/pull/123) — Fixture'
FINAL_HEADER_TABLE_HEADER='| Field | Value |'
FINAL_HEADER_TABLE_SEPARATOR='|---|---|'
FINAL_HEADER_TASK='| **Task** | FIX-123 — Fixture |'
FINAL_HEADER_BASE='| **Base** | `main` → `fixture` |'
FINAL_HEADER_FILES='| **Files changed** | 1 · +1 / −0 |'
FINAL_HEADER_AUTHOR='| **Author** | Fixture Author (@fixture) |'

valid_comparison="$test_root/comparison-valid.md"
cp -- "$test_dir/fixtures/comparison-valid-en.md" "$valid_comparison"
assert_true 'language-independent comparison markers validate' \
    validate_comparison_markers "$valid_comparison"

malformed_comparison="$test_root/comparison-malformed.md"
cp -- "$test_dir/fixtures/comparison-malformed.md" "$malformed_comparison"
assert_false 'malformed comparison fixture is rejected' \
    validate_comparison_markers "$malformed_comparison"
assert_file_contains "$malformed_comparison" '## Material disagreements' \
    'malformed comparison preserves useful diagnostics'

final_output="$test_root/final.md"
cp -- "$test_dir/fixtures/final-model-body.md" "$final_output"
normalize_final_markdown "$final_output"
assert_true 'normalized final Markdown satisfies the canonical header contract' \
    validate_final_markdown "$final_output"
first_line=$(sed -n '1p' "$final_output")
assert_eq "$FINAL_HEADER_TITLE" "$first_line" 'model progress prose is removed before the final report'
assert_false 'discarded finalizer preamble is absent' \
    grep -Fq 'I now have sufficient evidence' "$final_output"

CHANGED_LINE_MAP_FILE="$test_dir/fixtures/changed-lines-valid.json"
anchor_output="$test_root/final-anchors-valid.md"
anchor_validation="$test_root/final-anchors-valid.json"
cp -- "$test_dir/fixtures/final-anchors-valid.md" "$anchor_output"
normalize_final_markdown "$anchor_output"
assert_true 'changed-line and explicit PR-level anchors validate' \
    validate_final_anchors "$anchor_output" "$anchor_validation"
assert_eq 'complete' "$(jq -r '.status' "$anchor_validation")" \
    'valid anchor sidecar records complete validation'
assert_eq '2' "$(jq -r '.findings | length' "$anchor_validation")" \
    'anchor validator records every confirmed detailed finding'

classification_word_output="$test_root/final-confirmed-word-outside-classification.md"
cat >"$classification_word_output" <<EOF
${FINAL_CLASSIFICATION_HEADING}

${FINAL_CLASSIFICATION_TABLE_HEADER}
|---|---|---|---|---|---|
| 1 | Alpha | The report literally mentions CONFIRMED here | REJECTED | — | Not actionable. |
| 2 | Beta | A verified positive fact | CONFIRMED | — | No engineering action is required. |
EOF
assert_eq '0' "$(count_detailed_final_findings "$classification_word_output")" \
    'detailed-finding count ignores claims that only appear in the classification ledger'

positive_fact_anchor_output="$test_root/final-anchors-positive-fact.md"
positive_fact_validation="$test_root/final-anchors-positive-fact.json"
awk '
    { print }
    /Missing integration test.*CONFIRMED.*P2/ {
        print "| 3 | Alpha | Verified compatibility remains intact | CONFIRMED | — | Positive evidence. |"
    }
' "$test_dir/fixtures/final-anchors-valid.md" >"$positive_fact_anchor_output"
normalize_final_markdown "$positive_fact_anchor_output"
assert_true 'confirmed positive evidence does not require an actionable anchor block' \
    validate_final_anchors "$positive_fact_anchor_output" "$positive_fact_validation"
assert_eq '2' "$(jq -r '.confirmed_findings' "$positive_fact_validation")" \
    'anchor validation reports only detailed actionable findings'

duplicate_row_anchor_output="$test_root/final-anchors-duplicate-row.md"
duplicate_row_validation="$test_root/final-anchors-duplicate-row.json"
awk '
    { print }
    /Missing integration test.*CONFIRMED.*P2/ {
        print "| 3 | Alpha | Duplicate merged into row 2 recommendation | CONFIRMED | P2 | No separate detailed block. |"
    }
' "$test_dir/fixtures/final-anchors-valid.md" >"$duplicate_row_anchor_output"
normalize_final_markdown "$duplicate_row_anchor_output"
assert_true 'confirmed duplicate ledger row may be merged into another actionable finding' \
    validate_final_anchors "$duplicate_row_anchor_output" "$duplicate_row_validation"
assert_eq '2' "$(jq -r '.confirmed_findings' "$duplicate_row_validation")" \
    'duplicate classification rows do not inflate detailed finding parity'

context_output="$test_root/final-anchor-context-invalid.md"
context_validation="$test_root/final-anchor-context-invalid.json"
cp -- "$test_dir/fixtures/final-anchor-context-invalid.md" "$context_output"
normalize_final_markdown "$context_output"
assert_false 'context-only RIGHT-side line is rejected' \
    validate_final_anchors "$context_output" "$context_validation"
assert_eq 'line_not_changed_on_right_side' "$(jq -r '.findings[0].reason' "$context_validation")" \
    'invalid context anchor has a machine-readable reason'

# git reuses old lines where it can, so the closing brace of a new block is often
# printed as unchanged context. A range over the changed lines that ends on such
# a line points at exactly the change, and the diff hunk lets GitHub place it.
hunk_map="$test_root/changed-lines-with-hunks.json"
jq '(.files[] | select(.path == "src/Changed.php")) += {right_side_hunks: [{start: 7, "end": 16}]}' \
    "$test_dir/fixtures/changed-lines-valid.json" >"$hunk_map"
overrun_output="$test_root/final-anchor-overrun.md"
sed 's/^Line: `13`$/Line: `11-13`/' "$test_dir/fixtures/final-anchor-context-invalid.md" >"$overrun_output"
normalize_final_markdown "$overrun_output"
CHANGED_LINE_MAP_FILE="$test_dir/fixtures/changed-lines-valid.json"
assert_false 'a range ending on a context line is rejected by a map that records no hunks' \
    validate_final_anchors "$overrun_output" "$test_root/final-anchor-overrun-old.json"
CHANGED_LINE_MAP_FILE=$hunk_map
sed 's/^Line: `13`$/Line: `11-13`/' "$test_dir/fixtures/final-anchor-context-invalid.md" >"$overrun_output"
normalize_final_markdown "$overrun_output"
assert_true 'and accepted where the context line lies inside the hunk of the changed lines it covers' \
    validate_final_anchors "$overrun_output" "$test_root/final-anchor-overrun.json"
context_again="$test_root/final-anchor-context-again.md"
cp -- "$test_dir/fixtures/final-anchor-context-invalid.md" "$context_again"
normalize_final_markdown "$context_again"
assert_false 'while a line of context alone is still no anchor' \
    validate_final_anchors "$context_again" "$test_root/final-anchor-context-again.json"
CHANGED_LINE_MAP_FILE="$test_dir/fixtures/changed-lines-valid.json"

deleted_output="$test_root/final-anchor-deleted-invalid.md"
deleted_validation="$test_root/final-anchor-deleted-invalid.json"
sed 's@src/Changed.php@src/Deleted.php@g; s@`13`@`1`@g' \
    "$test_dir/fixtures/final-anchor-context-invalid.md" >"$deleted_output"
normalize_final_markdown "$deleted_output"
assert_false 'deleted file cannot supply a RIGHT-side changed-line anchor' \
    validate_final_anchors "$deleted_output" "$deleted_validation"

binary_output="$test_root/final-anchor-binary-invalid.md"
binary_validation="$test_root/final-anchor-binary-invalid.json"
sed 's@src/Changed.php@assets/image.bin@g; s@`13`@`1`@g' \
    "$test_dir/fixtures/final-anchor-context-invalid.md" >"$binary_output"
normalize_final_markdown "$binary_output"
assert_false 'binary file cannot supply a line anchor' \
    validate_final_anchors "$binary_output" "$binary_validation"

reversed_output="$test_root/final-anchor-reversed-invalid.md"
reversed_validation="$test_root/final-anchor-reversed-invalid.json"
sed 's@`13`@`20-10`@g' \
    "$test_dir/fixtures/final-anchor-context-invalid.md" >"$reversed_output"
normalize_final_markdown "$reversed_output"
assert_false 'reversed changed-line range is rejected' \
    validate_final_anchors "$reversed_output" "$reversed_validation"
assert_eq 'reversed_line_range' "$(jq -r '.findings[0].reason' "$reversed_validation")" \
    'reversed range has a stable reason code'

CHANGED_LINE_MAP_FILE=""
missing_map_validation="$test_root/final-anchors-map-unavailable.json"
assert_true 'historical final validation remains compatible when the map is absent' \
    validate_final_anchors "$anchor_output" "$missing_map_validation"
assert_eq 'unavailable' "$(jq -r '.status' "$missing_map_validation")" \
    'missing historical map is explicit rather than silently treated as verified'
CHANGED_LINE_MAP_FILE="$test_dir/fixtures/changed-lines-valid.json"

usage_output="$test_root/usage.json"
usage_total="$test_root/usage.total"
extract_token_usage \
    "$test_dir/fixtures/usage-claude.jsonl" \
    "$usage_total" \
    "$usage_output" \
    claude \
    'primary review' \
    claude-fixture \
    high
assert_eq '2300' "$(jq -r '.reported_total_tokens' "$usage_output")" \
    'usage totals use non-overlapping input/output/cache components'

# A provider that reports usage per request, not cumulatively, is billed for the
# whole conversation: every turn resends the context. The summary must say what
# the run actually costs, not what its last request happened to carry.
pi_multi_usage="$test_root/usage-pi-multi.json"
extract_token_usage \
    "$test_dir/fixtures/usage-pi-multi-request.jsonl" \
    "$test_root/usage-pi-multi.total" \
    "$pi_multi_usage" \
    pi \
    'primary review' \
    local-fixture \
    ''
assert_eq '6000' "$(jq -r '.input_tokens' "$pi_multi_usage")" \
    'per-request input tokens are summed over the whole conversation'
assert_eq '60' "$(jq -r '.output_tokens' "$pi_multi_usage")" \
    'per-request output tokens are summed over the whole conversation'
assert_eq '6' "$(jq -r '.reasoning_tokens' "$pi_multi_usage")" \
    'reasoning tokens are summed as well'
assert_eq '6060' "$(jq -r '.reported_total_tokens' "$pi_multi_usage")" \
    'the reported total is the billed total, not the final context'
assert_eq '3' "$(jq -r '.requests' "$pi_multi_usage")" \
    'the number of model requests is recorded'
assert_eq '3000' "$(jq -r '.final_context_tokens' "$pi_multi_usage")" \
    'the last request context is kept separately, since it bounds the window'
assert_eq 'stop' "$(jq -r '.stop_reason' "$pi_multi_usage")" \
    'the stop reason still comes from the last assistant message'
assert_eq '1' "$(jq -r '.context_compactions' "$pi_multi_usage")" \
    'a context compaction is counted, since it means the window overflowed'

pi_error_usage="$test_root/usage-pi-error.json"
extract_token_usage \
    "$test_dir/fixtures/usage-pi-error.jsonl" \
    "$test_root/usage-pi-error.total" \
    "$pi_error_usage" \
    pi \
    'primary review' \
    local-fixture \
    ''
assert_eq 'error' "$(jq -r '.stop_reason' "$pi_error_usage")" \
    'a failed Pi turn records the error stop reason'
assert_eq 'Connection error.' "$(jq -r '.error_message' "$pi_error_usage")" \
    'a failed Pi turn preserves the provider error message'
assert_eq 'null' "$(jq -r '.error_message' "$usage_output")" \
    'a successful turn records no error message'
assert_eq '0' "$(jq -r '.context_compactions' "$pi_error_usage")" \
    'a conversation that never compacted reports zero, not unknown'
assert_eq 'null' "$(jq -r '.context_compactions' "$usage_output")" \
    'a CLI that does not report compaction leaves the count unknown'

stale_manifest="$test_root/stale-manifest.json"
jq -n '{schema_version: 1, run_type: "full", review_id: "123-fixture", pr_number: 123,
        head_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", github_repository: "example/repository",
        reviewers: ["alpha", "beta"], status: {}, artifacts: {}}' >"$stale_manifest"
REVIEW_ID=123-fixture
PR_NUMBER=123
GITHUB_REPOSITORY=example/repository
HEAD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
assert_eq 'the PR head moved from aaaaaaaaaaaa to bbbbbbbbbbbb; start a new run for the current head' \
    "$(describe_manifest_incompatibility "$stale_manifest")" \
    'a manifest recorded for an older PR head explains the head change'
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert_eq '' "$(describe_manifest_incompatibility "$stale_manifest")" \
    'a compatible manifest has no incompatibility reason'
jq '.run_type = "final-rerun"' "$stale_manifest" >"$test_root/rerun-manifest.json"
assert_eq 'run_type is final-rerun, not a full run' \
    "$(describe_manifest_incompatibility "$test_root/rerun-manifest.json")" \
    'a non-full manifest names its run type'
assert_eq 'high' "$(jq -r '.reasoning_effort' "$usage_output")" \
    'usage summary records configured reasoning effort'

second_usage="$test_root/usage-second.json"
merged_usage="$test_root/usage-merged.json"
jq '.reported_total_tokens = 17 | .input_tokens = 10 | .output_tokens = 7' \
    "$usage_output" >"$second_usage"
merge_usage_summaries "$usage_output" "$second_usage" "$merged_usage"
assert_eq '2317' "$(jq -r '.reported_total_tokens' "$merged_usage")" \
    'multi-pass usage totals are accumulated'
assert_eq '2' "$(jq -r '.passes | length' "$merged_usage")" \
    'multi-pass usage keeps per-pass diagnostics'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
