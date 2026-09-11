#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

test_root=$(portable_mktemp_dir review-pr-finding-contract)
trap 'rm -rf -- "$test_root"' EXIT

WORK_DIR=$test_root
REPORT_STEM=fixture-en
PRIMARY_REVIEW_LANGUAGE=EN
CHANGED_LINE_MAP_FILE="$test_dir/fixtures/changed-lines-valid.json"
input="$test_root/primary.ndjson"
cp -- "$test_dir/fixtures/primary-findings-valid.ndjson" "$input"
PRIMARY_RAW_OUTPUTS[codex]="$test_root/fixture-en-codex-raw.ndjson"
PRIMARY_FINDINGS_OUTPUTS[codex]="$test_root/fixture-en-codex-findings.json"

assert_true 'valid ndjson-v1 primary output is accepted' \
    process_primary_ndjson_output "$input" codex
assert_true 'raw agent response is preserved byte-for-byte' \
    cmp -s "$test_dir/fixtures/primary-findings-valid.ndjson" "${PRIMARY_RAW_OUTPUTS[codex]}"
assert_eq ndjson-v1 "$(jq -r '.contract' "${PRIMARY_FINDINGS_OUTPUTS[codex]}")" \
    'canonical finding artifact records its protocol'
assert_eq '2' "$(jq -r '.finding_count' "${PRIMARY_FINDINGS_OUTPUTS[codex]}")" \
    'canonical finding count matches the completed stream'
assert_file_contains "$input" '<!-- review-pr:anchor:changed-line -->' \
    'renderer preserves a machine-independent changed-line marker'
assert_file_contains "$input" 'Line: `10`' \
    'renderer emits the validated RIGHT-side line'
assert_file_contains "$input" '## Verification limitations' \
    'renderer emits an explicit limitations section'

valid_canonical="$test_root/valid-canonical.json"
cp -- "${PRIMARY_FINDINGS_OUTPUTS[codex]}" "$valid_canonical"
repairable_preamble="$test_root/repairable-preamble.ndjson"
{
    printf '%s\n' 'Here is the requested structured review:'
    cat -- "$test_dir/fixtures/primary-findings-valid.ndjson"
} >"$repairable_preamble"
repair_baseline="$test_root/repair-baseline.json"
assert_true 'leading transport prose produces a safe repair baseline' \
    build_primary_repair_baseline "$repairable_preamble" "$repair_baseline"
assert_true 'unchanged canonical findings satisfy repair stability' \
    validate_primary_repair_stability "$repair_baseline" "$valid_canonical"

changed_canonical="$test_root/changed-canonical.json"
jq '.findings[0].claim = "The repair rewrote the claim."' "$valid_canonical" >"$changed_canonical"
assert_false 'repair stability rejects changed finding content' \
    validate_primary_repair_stability "$repair_baseline" "$changed_canonical"

broken_record="$test_root/broken-record.ndjson"
{
    sed -n '1p' "$test_dir/fixtures/primary-findings-valid.ndjson"
    printf '%s\n' '{"record":"finding","source_id":"broken"'
    sed -n '2,$p' "$test_dir/fixtures/primary-findings-valid.ndjson"
} >"$broken_record"
assert_false 'an unparseable JSON-looking record is ineligible for repair' \
    build_primary_repair_baseline "$broken_record" "$test_root/broken-baseline.json"

unknown_record="$test_root/unknown-record.ndjson"
printf '%s\n' '{"record":"unknown","schema_version":1}' >"$unknown_record"
assert_false 'an unknown record type is ineligible for repair' \
    build_primary_repair_baseline "$unknown_record" "$test_root/unknown-baseline.json"

missing_claim="$test_root/missing-claim.ndjson"
jq -c 'del(.claim)' < <(sed -n '1p' "$test_dir/fixtures/primary-findings-valid.ndjson") >"$missing_claim"
sed -n '$p' "$test_dir/fixtures/primary-findings-valid.ndjson" >>"$missing_claim"
assert_false 'a finding missing substantive content is ineligible for repair' \
    build_primary_repair_baseline "$missing_claim" "$test_root/missing-claim-baseline.json"

cross_records="$test_root/cross-records.json"
cross_expected_refs="$test_root/cross-expected-refs.json"
cross_canonical="$test_root/cross-canonical.json"
printf '%s\n' '[{"agent":"beta","source_id":"beta:F-001"}]' >"$cross_expected_refs"
jq -n '{
    record: "finding", schema_version: 1, source_id: "alpha:C-001",
    source_refs: [{agent: "beta", source_id: "beta:F-001"}],
    title: "Fixture cross classification", claim: "The changed branch can fail.",
    anchor: {kind: "changed-line", file: "src/Changed.php", start: 10, end: 10},
    evidence: ["The changed line confirms the failure path."],
    failure_scenario: "The request reaches the changed branch.",
    recommendation: "Correct the changed branch.", classification: "CONFIRMED",
    severity: "P1", category: "correctness", contributing_agents: ["beta"],
    verification_limitations: [], existing_feedback: {state: "new", thread_ids: []}
}, {
    record: "complete", schema_version: 1, finding_count: 1,
    summary: "One source finding confirmed.", verification_limitations: [], positive_evidence: []
}' | jq -s '.' >"$cross_records"
assert_true 'valid cross-review records preserve complete source provenance' \
    validate_cross_ndjson_records "$cross_records" "$cross_canonical" alpha "$cross_expected_refs"
assert_eq 'beta:beta:F-001' "$(jq -r '.input_refs[0] | .agent + ":" + .source_id' "$cross_canonical")" \
    'canonical cross-review stores namespaced input provenance'

missing_cross_ref="$test_root/cross-missing-ref.json"
jq '.[0].source_refs = [{agent: "beta", source_id: "beta:F-002"}]' "$cross_records" >"$missing_cross_ref"
assert_false 'cross-review rejects missing and unknown source provenance' \
    validate_cross_ndjson_records "$missing_cross_ref" "$test_root/cross-missing-ref-canonical.json" alpha "$cross_expected_refs"

rejected_with_severity="$test_root/cross-rejected-severity.json"
jq '.[0].classification = "REJECTED"' "$cross_records" >"$rejected_with_severity"
assert_false 'rejected cross-review findings cannot retain actionable severity' \
    validate_cross_ndjson_records "$rejected_with_severity" "$test_root/cross-rejected-severity-canonical.json" alpha "$cross_expected_refs"

rejected_empty_scenario="$test_root/cross-rejected-empty-scenario.json"
rejected_empty_canonical="$test_root/cross-rejected-empty-canonical.json"
jq '.[0].classification = "REJECTED" | .[0].severity = null | .[0].failure_scenario = ""' "$cross_records" >"$rejected_empty_scenario"
assert_true 'a rejected cross-review claim may leave failure_scenario empty' \
    validate_cross_ndjson_records "$rejected_empty_scenario" "$rejected_empty_canonical" alpha "$cross_expected_refs"
uncertain_empty_scenario="$test_root/cross-uncertain-empty-scenario.json"
jq '.[0].classification = "UNCERTAIN" | .[0].severity = null | .[0].failure_scenario = ""' "$cross_records" >"$uncertain_empty_scenario"
assert_true 'an uncertain cross-review claim may leave failure_scenario empty' \
    validate_cross_ndjson_records "$uncertain_empty_scenario" "$test_root/cross-uncertain-empty-canonical.json" alpha "$cross_expected_refs"
rejected_null_scenario="$test_root/cross-rejected-null-scenario.json"
rejected_null_canonical="$test_root/cross-rejected-null-canonical.json"
jq '.[0].classification = "REJECTED" | .[0].severity = null | .[0].failure_scenario = null' "$cross_records" >"$rejected_null_scenario"
assert_true 'a rejected cross-review claim may use a null failure_scenario' \
    validate_cross_ndjson_records "$rejected_null_scenario" "$rejected_null_canonical" alpha "$cross_expected_refs"
rejected_null_rendered="$test_root/cross-rejected-null.md"
assert_true 'a rejected claim with a null failure scenario renders' \
    render_cross_findings_markdown "$rejected_null_canonical" "$rejected_null_rendered" EN
assert_eq '_None._' "$(grep -A2 '^Failure scenario:$' "$rejected_null_rendered" | tail -1)" \
    'renderer substitutes a placeholder for a null failure scenario'
confirmed_empty_scenario="$test_root/cross-confirmed-empty-scenario.json"
jq '.[0].failure_scenario = ""' "$cross_records" >"$confirmed_empty_scenario"
assert_false 'a confirmed cross-review finding still requires a failure scenario' \
    validate_cross_ndjson_records "$confirmed_empty_scenario" "$test_root/cross-confirmed-empty-canonical.json" alpha "$cross_expected_refs"
assert_eq 'finding[alpha:C-001].failure_scenario' \
    "$(describe_ndjson_validation_failure cross "$confirmed_empty_scenario" alpha "$cross_expected_refs")" \
    'validation diagnostics name the record and field that failed'
assert_eq 'source_refs.missing[beta:beta:F-001], source_refs.unknown[beta:beta:F-002]' \
    "$(describe_ndjson_validation_failure cross "$missing_cross_ref" alpha "$cross_expected_refs")" \
    'validation diagnostics list missing and unknown source refs'
assert_eq '' "$(describe_ndjson_validation_failure cross "$cross_records" alpha "$cross_expected_refs")" \
    'validation diagnostics are empty for a valid stream'
rejected_empty_rendered="$test_root/cross-rejected-empty.md"
assert_true 'a rejected claim without a failure scenario renders' \
    render_cross_findings_markdown "$rejected_empty_canonical" "$rejected_empty_rendered" EN
assert_eq '_None._' "$(grep -A2 '^Failure scenario:$' "$rejected_empty_rendered" | tail -1)" \
    'renderer substitutes a placeholder for an empty failure scenario'

wrong_contributor="$test_root/cross-wrong-contributor.json"
jq '.[0].contributing_agents = ["alpha"]' "$cross_records" >"$wrong_contributor"
assert_false 'cross-review contributing agents must match source provenance' \
    validate_cross_ndjson_records "$wrong_contributor" "$test_root/cross-wrong-contributor-canonical.json" alpha "$cross_expected_refs"

cross_repairable="$test_root/cross-repairable.ndjson"
{
    printf '%s\n' 'Structured cross-review follows:'
    jq -c '.[]' "$cross_records"
} >"$cross_repairable"
cross_repair_baseline="$test_root/cross-repair-baseline.json"
assert_true 'cross-review transport prose produces a safe repair baseline' \
    build_cross_repair_baseline "$cross_repairable" "$cross_repair_baseline"
assert_true 'unchanged cross-review classification and provenance satisfy repair stability' \
    validate_cross_repair_stability "$cross_repair_baseline" "$cross_canonical"
changed_cross_canonical="$test_root/cross-changed-classification.json"
jq '.findings[0].classification = "UNCERTAIN" | .findings[0].severity = null' "$cross_canonical" >"$changed_cross_canonical"
assert_false 'cross-review repair stability rejects reclassification' \
    validate_cross_repair_stability "$cross_repair_baseline" "$changed_cross_canonical"

REVIEW_AGENTS=(alpha)
CROSS_FINDINGS_OUTPUTS[alpha]="$cross_canonical"
final_expected_refs="$test_root/final-expected-refs.json"
assert_true 'final synthesis derives cross-review inputs and transitive primary provenance' \
    build_final_expected_refs "$final_expected_refs"
assert_eq 'beta:beta:F-001' "$(jq -r '.[0].primary_refs[0] | .agent + ":" + .source_id' "$final_expected_refs")" \
    'final expected refs retain canonical primary provenance'

final_records="$test_root/final-records.json"
final_canonical="$test_root/final-canonical.json"
jq -n '{
    record: "finding", schema_version: 1, source_id: "FINAL-001",
    source_refs: [{agent: "alpha", source_id: "alpha:C-001"}],
    title: "Fixture final finding", claim: "The changed branch can fail.",
    anchor: {kind: "changed-line", file: "src/Changed.php", start: 10, end: 10},
    evidence: ["The canonical cross-review confirms the changed failure path."],
    failure_scenario: "The request reaches the changed branch.", recommendation: "Correct the branch.",
    classification: "CONFIRMED", severity: "P1", category: "correctness",
    contributing_agents: ["alpha"], verification_limitations: [],
    existing_feedback: {state: "new", thread_ids: []}, include_in_rejected_summary: false
}, {
    record: "complete", schema_version: 1, finding_count: 1,
    summary: "One finding confirmed.", verification_limitations: [], positive_evidence: []
}' | jq -s '.' >"$final_records"
assert_true 'valid final synthesis covers every canonical cross-review source' \
    validate_final_ndjson_records "$final_records" "$final_canonical" "$final_expected_refs"
assert_eq 'beta:beta:F-001' "$(jq -r '.findings[0].primary_refs[0] | .agent + ":" + .source_id' "$final_canonical")" \
    'canonical final sidecar derives primary provenance instead of trusting the model'

final_missing_ref="$test_root/final-missing-ref.json"
jq '.[0].source_refs[0].source_id = "alpha:C-999"' "$final_records" >"$final_missing_ref"
assert_false 'final synthesis rejects missing and unknown cross-review provenance' \
    validate_final_ndjson_records "$final_missing_ref" "$test_root/final-missing-canonical.json" "$final_expected_refs"

final_bad_rejected_flag="$test_root/final-bad-rejected-flag.json"
jq '.[0].include_in_rejected_summary = true' "$final_records" >"$final_bad_rejected_flag"
assert_false 'only rejected findings may enter the important-rejections summary' \
    validate_final_ndjson_records "$final_bad_rejected_flag" "$test_root/final-bad-flag-canonical.json" "$final_expected_refs"
assert_eq 'finding[FINAL-001].include_in_rejected_summary' \
    "$(describe_ndjson_validation_failure final "$final_bad_rejected_flag" '' "$final_expected_refs")" \
    'final validation diagnostics name the failing decision field'

final_rejected_empty_scenario="$test_root/final-rejected-empty-scenario.json"
jq '.[0].classification = "REJECTED" | .[0].severity = null | .[0].failure_scenario = ""' "$final_records" >"$final_rejected_empty_scenario"
assert_true 'a rejected final claim may leave failure_scenario empty' \
    validate_final_ndjson_records "$final_rejected_empty_scenario" "$test_root/final-rejected-empty-canonical.json" "$final_expected_refs"
final_rejected_null_scenario="$test_root/final-rejected-null-scenario.json"
jq '.[0].classification = "REJECTED" | .[0].severity = null | .[0].failure_scenario = null' "$final_records" >"$final_rejected_null_scenario"
assert_true 'a rejected final claim may use a null failure_scenario' \
    validate_final_ndjson_records "$final_rejected_null_scenario" "$test_root/final-rejected-null-canonical.json" "$final_expected_refs"
final_confirmed_null_scenario="$test_root/final-confirmed-null-scenario.json"
jq '.[0].failure_scenario = null' "$final_records" >"$final_confirmed_null_scenario"
assert_false 'a confirmed final finding rejects a null failure scenario' \
    validate_final_ndjson_records "$final_confirmed_null_scenario" "$test_root/final-confirmed-null-canonical.json" "$final_expected_refs"
final_confirmed_empty_scenario="$test_root/final-confirmed-empty-scenario.json"
jq '.[0].failure_scenario = ""' "$final_records" >"$final_confirmed_empty_scenario"
assert_false 'a confirmed final finding still requires a failure scenario' \
    validate_final_ndjson_records "$final_confirmed_empty_scenario" "$test_root/final-confirmed-empty-canonical.json" "$final_expected_refs"

final_repairable="$test_root/final-repairable.ndjson"
{
    printf '%s\n' 'Structured final synthesis follows:'
    jq -c '.[]' "$final_records"
} >"$final_repairable"
final_repair_baseline="$test_root/final-repair-baseline.json"
assert_true 'final transport prose produces a safe repair baseline' \
    build_final_repair_baseline "$final_repairable" "$final_repair_baseline"
assert_true 'unchanged final decisions and provenance satisfy repair stability' \
    validate_final_repair_stability "$final_repair_baseline" "$final_canonical"
changed_final_canonical="$test_root/final-changed-classification.json"
jq '.findings[0].classification = "UNCERTAIN" | .findings[0].severity = null' "$final_canonical" >"$changed_final_canonical"
assert_false 'final repair stability rejects reclassification' \
    validate_final_repair_stability "$final_repair_baseline" "$changed_final_canonical"
changed_final_flag="$test_root/final-changed-rejection-flag.json"
jq '.findings[0].include_in_rejected_summary = true' "$final_canonical" >"$changed_final_flag"
assert_false 'final repair stability rejects changes to rejection presentation decisions' \
    validate_final_repair_stability "$final_repair_baseline" "$changed_final_flag"

FINALIZATION_LANGUAGE=EN
FINAL_HEADER_TITLE='# Code Review: [PR #1](https://example.test/1) — Fixture'
FINAL_HEADER_TABLE_HEADER='| Field | Value |'
FINAL_HEADER_TABLE_SEPARATOR='| --- | --- |'
FINAL_HEADER_TASK='| **Task** | Fixture |'
FINAL_HEADER_BASE='| **Base** | `main` → `fixture` |'
FINAL_HEADER_FILES='| **Files changed** | 1 · +1 / −0 |'
FINAL_HEADER_AUTHOR='| **Author** | Fixture |'
configure_finalization_language
final_rendered="$test_root/final-rendered.md"
assert_true 'canonical final findings render deterministic Markdown' \
    render_final_findings_markdown "$final_canonical" "$final_rendered"
assert_file_contains "$final_rendered" "$FINAL_CLASSIFICATION_TABLE_HEADER" \
    'final renderer owns the localized classification header'
assert_file_contains "$final_rendered" '<!-- review-pr:anchor:changed-line -->' \
    'final renderer emits the stable changed-line anchor marker'
assert_true 'deterministic final Markdown passes the legacy structural validator' \
    validate_final_markdown "$final_rendered"

REPORT_STEM=fixture-ua
PRIMARY_REVIEW_LANGUAGE=UA
ua_input="$test_root/primary-ua.ndjson"
cp -- "$test_dir/fixtures/primary-findings-valid.ndjson" "$ua_input"
PRIMARY_RAW_OUTPUTS[codex]="$test_root/fixture-ua-codex-raw.ndjson"
PRIMARY_FINDINGS_OUTPUTS[codex]="$test_root/fixture-ua-codex-findings.json"
assert_true 'the same machine contract renders in Ukrainian' \
    process_primary_ndjson_output "$ua_input" codex
assert_file_contains "$ua_input" '## Знахідки' \
    'localized Markdown is generated without localized parser controls'
assert_file_contains "$ua_input" '## Обмеження перевірки' \
    'Ukrainian renderer localizes the limitations heading'

assert_invalid_contract() {
    local label=$1
    local expected_reason=$2
    local source=$3
    local candidate="$test_root/${label}.ndjson"

    REPORT_STEM="fixture-${label}"
    PRIMARY_REVIEW_LANGUAGE=EN
    PRIMARY_RAW_OUTPUTS[codex]="$test_root/fixture-${label}-codex-raw.ndjson"
    PRIMARY_FINDINGS_OUTPUTS[codex]="$test_root/fixture-${label}-codex-findings.json"
    cp -- "$source" "$candidate"
    assert_false "$label is rejected" process_primary_ndjson_output "$candidate" codex
    assert_eq "$expected_reason" "$FINDING_CONTRACT_FAILURE_REASON" \
        "$label has a stable failure reason"
    assert_file_not_exists "${PRIMARY_RAW_OUTPUTS[codex]}" \
        "$label cannot publish a canonical raw artifact"
    assert_file_not_exists "${PRIMARY_FINDINGS_OUTPUTS[codex]}" \
        "$label cannot publish canonical findings"
}

duplicate_ids="$test_root/duplicate-source.ndjson"
sed 's/"source_id":"F-002"/"source_id":"F-001"/' \
    "$test_dir/fixtures/primary-findings-valid.ndjson" >"$duplicate_ids"
assert_invalid_contract duplicate-source-id 'schema_or_completeness_validation_failed: stream.duplicate_source_id[F-001]' "$duplicate_ids"

truncated="$test_root/truncated-source.ndjson"
sed '$d' "$test_dir/fixtures/primary-findings-valid.ndjson" >"$truncated"
assert_invalid_contract missing-complete 'schema_or_completeness_validation_failed: stream.no_complete' "$truncated"

wrong_line="$test_root/wrong-line-source.ndjson"
sed 's/"start":10,"end":10/"start":13,"end":13/' \
    "$test_dir/fixtures/primary-findings-valid.ndjson" >"$wrong_line"
assert_invalid_contract context-line 'schema_or_completeness_validation_failed: finding[F-001].anchor' "$wrong_line"

classified="$test_root/classified-source.ndjson"
sed '0,/"classification":null/s//"classification":"CONFIRMED"/' \
    "$test_dir/fixtures/primary-findings-valid.ndjson" >"$classified"
assert_invalid_contract primary-classification 'schema_or_completeness_validation_failed: finding[F-001].classification' "$classified"

foreign_provenance="$test_root/foreign-provenance.ndjson"
sed '0,/"contributing_agents":\["codex"\]/s//"contributing_agents":["codex","claude"]/' \
    "$test_dir/fixtures/primary-findings-valid.ndjson" >"$foreign_provenance"
assert_invalid_contract foreign-primary-provenance 'schema_or_completeness_validation_failed: finding[F-001].contributing_agents' "$foreign_provenance"

missing_thread_id="$test_root/missing-thread-id.ndjson"
sed '0,/"state":"new","thread_ids":\[\]/s//"state":"confirmed-existing","thread_ids":[]/' \
    "$test_dir/fixtures/primary-findings-valid.ndjson" >"$missing_thread_id"
assert_invalid_contract missing-existing-thread-id 'schema_or_completeness_validation_failed: finding[F-001].existing_feedback' "$missing_thread_id"

preamble="$test_root/preamble-source.ndjson"
{
    printf '%s\n' 'Here is the requested review:'
    cat -- "$test_dir/fixtures/primary-findings-valid.ndjson"
} >"$preamble"
assert_invalid_contract prose-preamble invalid_json_line_1 "$preamble"

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
