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

wrong_contributor="$test_root/cross-wrong-contributor.json"
jq '.[0].contributing_agents = ["alpha"]' "$cross_records" >"$wrong_contributor"
assert_false 'cross-review contributing agents must match source provenance' \
    validate_cross_ndjson_records "$wrong_contributor" "$test_root/cross-wrong-contributor-canonical.json" alpha "$cross_expected_refs"

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
assert_invalid_contract duplicate-source-id schema_or_completeness_validation_failed "$duplicate_ids"

truncated="$test_root/truncated-source.ndjson"
sed '$d' "$test_dir/fixtures/primary-findings-valid.ndjson" >"$truncated"
assert_invalid_contract missing-complete schema_or_completeness_validation_failed "$truncated"

wrong_line="$test_root/wrong-line-source.ndjson"
sed 's/"start":10,"end":10/"start":13,"end":13/' \
    "$test_dir/fixtures/primary-findings-valid.ndjson" >"$wrong_line"
assert_invalid_contract context-line schema_or_completeness_validation_failed "$wrong_line"

classified="$test_root/classified-source.ndjson"
sed '0,/"classification":null/s//"classification":"CONFIRMED"/' \
    "$test_dir/fixtures/primary-findings-valid.ndjson" >"$classified"
assert_invalid_contract primary-classification schema_or_completeness_validation_failed "$classified"

foreign_provenance="$test_root/foreign-provenance.ndjson"
sed '0,/"contributing_agents":\["codex"\]/s//"contributing_agents":["codex","claude"]/' \
    "$test_dir/fixtures/primary-findings-valid.ndjson" >"$foreign_provenance"
assert_invalid_contract foreign-primary-provenance schema_or_completeness_validation_failed "$foreign_provenance"

missing_thread_id="$test_root/missing-thread-id.ndjson"
sed '0,/"state":"new","thread_ids":\[\]/s//"state":"confirmed-existing","thread_ids":[]/' \
    "$test_dir/fixtures/primary-findings-valid.ndjson" >"$missing_thread_id"
assert_invalid_contract missing-existing-thread-id schema_or_completeness_validation_failed "$missing_thread_id"

preamble="$test_root/preamble-source.ndjson"
{
    printf '%s\n' 'Here is the requested review:'
    cat -- "$test_dir/fixtures/primary-findings-valid.ndjson"
} >"$preamble"
assert_invalid_contract prose-preamble invalid_json_line_1 "$preamble"

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
