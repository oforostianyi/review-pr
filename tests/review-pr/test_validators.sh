#!/usr/bin/env bash

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
EOF
assert_eq '0' "$(count_confirmed_final_findings "$classification_word_output")" \
    'confirmed-finding count reads only the classification column'

context_output="$test_root/final-anchor-context-invalid.md"
context_validation="$test_root/final-anchor-context-invalid.json"
cp -- "$test_dir/fixtures/final-anchor-context-invalid.md" "$context_output"
normalize_final_markdown "$context_output"
assert_false 'context-only RIGHT-side line is rejected' \
    validate_final_anchors "$context_output" "$context_validation"
assert_eq 'line_not_changed_on_right_side' "$(jq -r '.findings[0].reason' "$context_validation")" \
    'invalid context anchor has a machine-readable reason'

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
