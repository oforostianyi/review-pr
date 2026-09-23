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

# A PHP namespace inside a JSON string is the single most likely way for a
# reviewer of PHP to emit an invalid escape: `GuzzleHttp\Handler` is not valid
# JSON, and a backslash before a character that starts no escape can only have
# meant a literal backslash. A whole finished stream was thrown away over one.
escape_input="$test_root/primary-invalid-escape.ndjson"
escape_raw="$test_root/fixture-en-escape-raw.ndjson"
escape_findings="$test_root/fixture-en-escape-findings.json"
python3 - "$test_dir/fixtures/primary-findings-valid.ndjson" "$escape_input" <<'PYTHON'
import json, sys

lines = [line for line in open(sys.argv[1], encoding='utf-8').read().split('\n') if line.strip()]
out = []
for line in lines:
    record = json.loads(line)
    if record.get('record') == 'finding' and record.get('recommendation'):
        record['recommendation'] = 'Mock it with GuzzleHttp\\Handler\\MockHandler instead.'
        # Undo JSON's own escaping so the line carries the lone backslashes a
        # model writes when it quotes a PHP namespace.
        out.append(json.dumps(record, ensure_ascii=False).replace('\\\\', '\\'))
    else:
        out.append(line)
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PYTHON
assert_false 'the fixture really is invalid JSON before the repair' \
    jq -e . "$escape_input"
saved_raw=${PRIMARY_RAW_OUTPUTS[codex]}
saved_findings=${PRIMARY_FINDINGS_OUTPUTS[codex]}
PRIMARY_RAW_OUTPUTS[codex]=$escape_raw
PRIMARY_FINDINGS_OUTPUTS[codex]=$escape_findings
escape_log="$test_root/escape-repair.log"
escape_status=0
process_primary_ndjson_output "$escape_input" codex 2>"$escape_log" || escape_status=$?
assert_eq 0 "$escape_status" 'a lone backslash inside a string does not fail the phase'
assert_file_contains "$escape_log" 'Repaired 2 invalid JSON escapes in the primary stream from codex' \
    'a repaired line is announced instead of being counted in silence'
assert_file_contains "$escape_findings" 'GuzzleHttp' \
    'the repaired record keeps the text the model wrote'
assert_eq '2' "$(jq -r '.finding_count' "$escape_findings")" \
    'every record of the stream survives the repair'
assert_eq 'GuzzleHttp\Handler\MockHandler' \
    "$(jq -r '.findings[0].recommendation | capture("(?<n>GuzzleHttp[^ ]*)").n' "$escape_findings")" \
    'the namespace reads as one literal backslash per separator, not two'
PRIMARY_RAW_OUTPUTS[codex]=$saved_raw
PRIMARY_FINDINGS_OUTPUTS[codex]=$saved_findings
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

# A reviewer that encodes "the file and the symbol" as an object instead of a
# string produces a stream the bounded repair may not rewrite, because the fix
# would change content. The validator must name the offending field.
structured_positive="$test_root/structured-positive-evidence.ndjson"
jq -c 'if .record == "complete" then .positive_evidence = [{file: "src/Changed.php", symbol: "Changed::run()", note: "traced and unaffected"}] else . end' \
    "$test_dir/fixtures/primary-findings-valid.ndjson" >"$structured_positive"
structured_positive_records="$test_root/structured-positive-records.json"
jq -s '.' "$structured_positive" >"$structured_positive_records"
assert_false 'objects inside positive_evidence are rejected' \
    validate_primary_ndjson_records "$structured_positive_records" "$test_root/structured-positive-canonical.json" codex
assert_eq 'complete.positive_evidence' \
    "$(describe_ndjson_validation_failure primary "$structured_positive_records" codex '')" \
    'the diagnostic names the terminal record field that carried objects'

unknown_record="$test_root/unknown-record.ndjson"
printf '%s\n' '{"record":"unknown","schema_version":1}' >"$unknown_record"
assert_false 'an unknown record type is ineligible for repair' \
    build_primary_repair_baseline "$unknown_record" "$test_root/unknown-baseline.json"

missing_claim="$test_root/missing-claim.ndjson"
jq -c 'del(.claim)' < <(sed -n '1p' "$test_dir/fixtures/primary-findings-valid.ndjson") >"$missing_claim"
sed -n '$p' "$test_dir/fixtures/primary-findings-valid.ndjson" >>"$missing_claim"
assert_false 'a finding missing substantive content is ineligible for repair' \
    build_primary_repair_baseline "$missing_claim" "$test_root/missing-claim-baseline.json"

missing_feedback="$test_root/missing-feedback.ndjson"
jq -c 'del(.existing_feedback)' < <(sed -n '1p' "$test_dir/fixtures/primary-findings-valid.ndjson") >"$missing_feedback"
jq -c '.existing_feedback = {state: "new", thread_ids: []}' < <(sed -n '2p' "$test_dir/fixtures/primary-findings-valid.ndjson") >>"$missing_feedback"
sed -n '3,$p' "$test_dir/fixtures/primary-findings-valid.ndjson" >>"$missing_feedback"
missing_feedback_baseline="$test_root/missing-feedback-baseline.json"
assert_true 'a finding missing only existing_feedback is eligible for repair' \
    build_primary_repair_baseline "$missing_feedback" "$missing_feedback_baseline"
assert_eq 'unknown' "$(jq -r '.findings[0].existing_feedback.state' "$missing_feedback_baseline")" \
    'the repair baseline records missing existing feedback as unknown'
assert_eq '[]' "$(jq -c '.findings[0].existing_feedback.thread_ids' "$missing_feedback_baseline")" \
    'the repair baseline gives missing existing feedback no thread ids'
assert_eq 'new' "$(jq -r '.findings[1].existing_feedback.state' "$missing_feedback_baseline")" \
    'findings that carry existing feedback keep it in the baseline'

cross_records="$test_root/cross-records.json"
cross_expected_refs="$test_root/cross-expected-refs.json"
cross_canonical="$test_root/cross-canonical.json"
printf '%s\n' '[{"agent":"beta","source_id":"beta:F-001"}]' >"$cross_expected_refs"
jq -n '{
    record: "finding", schema_version: 1, source_id: "alpha:C-001",
    source_refs: [{agent: "beta", source_id: "beta:F-001"}],
    title: "Fixture cross classification", claim: "The changed branch can fail.",
    anchor: {kind: "changed-line", file: "src/Changed.php", start: 10, "end": 10},
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
rejected_null_recommendation="$test_root/cross-rejected-null-recommendation.json"
jq '.[0].classification = "REJECTED" | .[0].severity = null | .[0].failure_scenario = null | .[0].recommendation = null' "$cross_records" >"$rejected_null_recommendation"
assert_true 'a rejected cross-review claim may use a null recommendation' \
    validate_cross_ndjson_records "$rejected_null_recommendation" "$test_root/cross-rejected-null-recommendation-canonical.json" alpha "$cross_expected_refs"
uncertain_empty_recommendation="$test_root/cross-uncertain-empty-recommendation.json"
jq '.[0].classification = "UNCERTAIN" | .[0].severity = null | .[0].recommendation = ""' "$cross_records" >"$uncertain_empty_recommendation"
assert_true 'an uncertain cross-review claim may leave recommendation empty' \
    validate_cross_ndjson_records "$uncertain_empty_recommendation" "$test_root/cross-uncertain-empty-recommendation-canonical.json" alpha "$cross_expected_refs"
confirmed_null_recommendation="$test_root/cross-confirmed-null-recommendation.json"
jq '.[0].recommendation = null' "$cross_records" >"$confirmed_null_recommendation"
assert_false 'a confirmed cross-review finding still requires a recommendation' \
    validate_cross_ndjson_records "$confirmed_null_recommendation" "$test_root/cross-confirmed-null-recommendation-canonical.json" alpha "$cross_expected_refs"
assert_eq 'finding[alpha:C-001].recommendation' \
    "$(describe_ndjson_validation_failure cross "$confirmed_null_recommendation" alpha "$cross_expected_refs")" \
    'cross-review diagnostics name the missing recommendation'
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

# A stream that stopped early is the one failure a no-tools schema repair cannot
# fix: the missing records need repository evidence, so it is continued instead.
assert_true 'an unanswered source ref with no terminal record is a truncated stream' \
    ndjson_failure_is_truncation 'stream.no_complete, source_refs.missing[beta:beta:F-001,gamma:gamma:F-002]'
assert_true 'an unanswered source ref alone is a truncated stream' \
    ndjson_failure_is_truncation 'source_refs.missing[beta:beta:F-001]'
assert_false 'a stream that answered every ref but omitted complete is left to schema repair' \
    ndjson_failure_is_truncation 'stream.no_complete'
assert_false 'a truncated stream carrying a malformed record is not continued' \
    ndjson_failure_is_truncation 'source_refs.missing[beta:beta:F-001], finding[alpha:C-001].claim'
assert_false 'an unknown source ref disqualifies continuation' \
    ndjson_failure_is_truncation 'source_refs.missing[beta:beta:F-001], source_refs.unknown[beta:beta:F-009]'
assert_false 'an empty diagnostic is not a truncated stream' \
    ndjson_failure_is_truncation ''
assert_false 'an unavailable diagnostic is not a truncated stream' \
    ndjson_failure_is_truncation 'diagnostics_unavailable'

# Continuing a truncated cross-review keeps every finding the agent produced and
# asks only for the source refs it never reached.
continuation_expected_refs="$test_root/continuation-expected-refs.json"
printf '%s\n' '[{"agent":"beta","source_id":"beta:F-001"},{"agent":"gamma","source_id":"gamma:F-002"}]' \
    >"$continuation_expected_refs"
truncated_draft="$test_root/cross-truncated.ndjson"
jq -c '.[0]' "$cross_records" >"$truncated_draft"
continuation_kept="$test_root/continuation-kept.ndjson"
continuation_pending="$test_root/continuation-pending.json"
assert_true 'a truncated cross-review draft yields a continuation state' \
    build_continuation_state cross "$truncated_draft" "$continuation_expected_refs" \
        "$continuation_kept" "$continuation_pending"
assert_eq '1' "$(grep -c '' "$continuation_kept")" \
    'the continuation keeps the findings the draft already produced'
assert_eq 'gamma:gamma:F-002' "$(jq -r '.[] | .agent + ":" + .source_id' "$continuation_pending")" \
    'the continuation asks only for the unanswered source refs'
completed_draft="$test_root/cross-completed.ndjson"
jq -c '.[]' "$cross_records" >"$completed_draft"
assert_true 'a draft that stopped after its own terminal record is still continued' \
    build_continuation_state cross "$completed_draft" "$continuation_expected_refs" \
        "$continuation_kept" "$continuation_pending"
assert_eq '1' "$(grep -c '' "$continuation_kept")" \
    'the superseded terminal record is dropped from the kept findings'
findingless_draft="$test_root/cross-findingless.ndjson"
jq -c '.[1]' "$cross_records" >"$findingless_draft"
assert_false 'a draft without a single finding cannot be continued' \
    build_continuation_state cross "$findingless_draft" "$continuation_expected_refs" \
        "$continuation_kept" "$continuation_pending"

# A continuation may only append. The findings the draft already produced must
# survive the merge unchanged, in their original order.
merged_records="$test_root/cross-merged.json"
jq -s '.[0] as $d | [$d[0],
    ($d[0] | .source_id = "alpha:C-002" | .source_refs = [{agent: "gamma", source_id: "gamma:F-002"}] |
        .contributing_agents = ["gamma"] | .title = "Continued cross classification"),
    ($d[1] | .finding_count = 2)]' "$cross_records" >"$merged_records"
merged_canonical="$test_root/cross-merged-canonical.json"
assert_true 'a merged continuation stream validates as one cross-review' \
    validate_cross_ndjson_records "$merged_records" "$merged_canonical" alpha "$continuation_expected_refs"
build_continuation_state cross "$truncated_draft" "$continuation_expected_refs" \
    "$continuation_kept" "$continuation_pending"
assert_true 'an appended continuation preserves the kept findings' \
    validate_continuation_prefix cross "$continuation_kept" "$merged_canonical"
rewritten_prefix="$test_root/cross-merged-rewritten.json"
jq '.findings[0].claim = "The continuation rewrote the kept claim."' "$merged_canonical" >"$rewritten_prefix"
assert_false 'a continuation that rewrites a kept finding is rejected' \
    validate_continuation_prefix cross "$continuation_kept" "$rewritten_prefix"
reordered_prefix="$test_root/cross-merged-reordered.json"
jq '.findings = [.findings[1], .findings[0]]' "$merged_canonical" >"$reordered_prefix"
assert_false 'a continuation that reorders the kept findings is rejected' \
    validate_continuation_prefix cross "$continuation_kept" "$reordered_prefix"
dropped_prefix="$test_root/cross-merged-dropped.json"
jq '.findings = [.findings[1]]' "$merged_canonical" >"$dropped_prefix"
assert_false 'a continuation that drops a kept finding is rejected' \
    validate_continuation_prefix cross "$continuation_kept" "$dropped_prefix"

# The merge is mechanical: the kept findings, then whatever the continuation
# returned, with the usual transport wrapper stripped from the new part only.
continuation_reply="$test_root/cross-continuation-reply.ndjson"
{
    printf '%s\n' '```ndjson'
    jq -c '.[1], .[2]' "$merged_records"
    printf '%s\n' '```'
} >"$continuation_reply"
merged_stream="$test_root/cross-merged-stream.ndjson"
assert_true 'a fenced continuation reply merges onto the kept findings' \
    merge_continuation_stream "$continuation_kept" "$continuation_reply" "$merged_stream"
assert_eq '3' "$(grep -c '' "$merged_stream")" 'the merged stream holds the kept and the continued records'
assert_eq 'complete' "$(tail -n 1 "$merged_stream" | jq -r '.record')" \
    'the merged stream ends with the continuation terminal record'
assert_eq 'alpha:C-001' "$(head -n 1 "$merged_stream" | jq -r '.source_id')" \
    'the merged stream opens with the kept finding'
merged_stream_records="$test_root/cross-merged-stream-records.json"
merged_stream_canonical="$test_root/cross-merged-stream-canonical.json"
jq -s '.' "$merged_stream" >"$merged_stream_records"
assert_true 'the merged stream satisfies the ordinary cross-review contract' \
    validate_cross_ndjson_records "$merged_stream_records" "$merged_stream_canonical" alpha "$continuation_expected_refs"
empty_reply="$test_root/cross-continuation-empty.ndjson"
: >"$empty_reply"
assert_false 'an empty continuation reply cannot be merged' \
    merge_continuation_stream "$continuation_kept" "$empty_reply" "$test_root/cross-merged-empty.ndjson"

# The continuation runs as a real review with repository access, so it repeats the
# original phase prompt. It learns which refs are done, never what was said about
# them: resending the produced findings would invite the agent to revise them.
continuation_prompt="$test_root/cross-continuation-prompt.txt"
original_prompt="$test_root/cross-original-prompt.txt"
printf '%s\n' 'ORIGINAL CROSS-REVIEW PROMPT BODY' >"$original_prompt"
assert_true 'a continuation prompt is written from the original phase prompt' \
    write_continuation_prompt cross "$continuation_prompt" "$original_prompt" \
        "$continuation_kept" "$continuation_pending"
assert_file_contains "$continuation_prompt" 'ORIGINAL CROSS-REVIEW PROMPT BODY' \
    'the continuation repeats the review it is finishing'
assert_file_contains "$continuation_prompt" 'gamma:F-002' \
    'the continuation prompt names the unanswered source ref'
assert_file_contains "$continuation_prompt" 'alpha:C-001' \
    'the continuation prompt names the findings already produced'
assert_file_contains "$continuation_prompt" 'finding_count' \
    'the continuation prompt states how the terminal record must count'
assert_false 'the continuation prompt withholds the content of the kept findings' \
    grep -Fq 'The changed branch can fail.' "$continuation_prompt"
assert_false 'a continuation prompt needs at least one unanswered source ref' \
    write_continuation_prompt cross "$test_root/cross-continuation-prompt-empty.txt" "$original_prompt" \
        "$continuation_kept" "$test_root/continuation-pending-empty.json"
rejected_empty_rendered="$test_root/cross-rejected-empty.md"
assert_true 'a rejected claim without a failure scenario renders' \
    render_cross_findings_markdown "$rejected_empty_canonical" "$rejected_empty_rendered" EN
assert_eq '_None._' "$(grep -A2 '^Failure scenario:$' "$rejected_empty_rendered" | tail -1)" \
    'renderer substitutes a placeholder for an empty failure scenario'

wrong_contributor="$test_root/cross-wrong-contributor.json"
jq '.[0].contributing_agents = ["alpha"]' "$cross_records" >"$wrong_contributor"
assert_false 'cross-review contributing agents must match source provenance' \
    validate_cross_ndjson_records "$wrong_contributor" "$test_root/cross-wrong-contributor-canonical.json" alpha "$cross_expected_refs"

cross_missing_feedback="$test_root/cross-missing-feedback.ndjson"
jq -c '.[0] | del(.existing_feedback)' "$cross_records" >"$cross_missing_feedback"
jq -c '.[1]' "$cross_records" >>"$cross_missing_feedback"
assert_true 'a cross-review finding missing only existing_feedback is eligible for repair' \
    build_cross_repair_baseline "$cross_missing_feedback" "$test_root/cross-missing-feedback-baseline.json"
assert_eq 'unknown' "$(jq -r '.findings[0].existing_feedback.state' "$test_root/cross-missing-feedback-baseline.json")" \
    'the cross-review repair baseline records missing existing feedback as unknown'

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

gamma_cross_canonical="$test_root/cross-gamma-canonical.json"
jq '.agent = "gamma" | .findings[0].source_id = "gamma:C-001" | .findings[0].classification = "REJECTED" | .findings[0].severity = null' \
    "$cross_canonical" >"$gamma_cross_canonical"
REVIEW_AGENTS=(alpha gamma)
CROSS_FINDINGS_OUTPUTS[gamma]="$gamma_cross_canonical"
disputes_file="$test_root/disputes.json"
assert_true 'dispute detection reads every canonical cross-review sidecar' \
    build_final_disputes "$disputes_file"
assert_eq '1' "$(jq 'length' "$disputes_file")" \
    'a primary ref classified CONFIRMED and REJECTED by different cross-reviewers is one dispute'
assert_eq 'dispute:beta:beta:F-001' "$(jq -r '.[0].dispute_id' "$disputes_file")" \
    'dispute ids derive from the primary ref'
assert_eq 'factual' "$(jq -r '.[0].kind_hint' "$disputes_file")" \
    'differing classifications hint at a factual dispute'
assert_eq 'alpha:alpha:C-001,gamma:gamma:C-001' \
    "$(jq -r '[.[0].conflicting_refs[] | .agent + ":" + .source_id] | join(",")' "$disputes_file")" \
    'conflicting refs list every cross-review record of the disputed primary ref in stable order'

severity_cross_canonical="$test_root/cross-gamma-severity.json"
jq '.findings[0].classification = "CONFIRMED" | .findings[0].severity = "P3"' "$gamma_cross_canonical" >"$severity_cross_canonical"
CROSS_FINDINGS_OUTPUTS[gamma]="$severity_cross_canonical"
assert_true 'dispute detection handles severity-only disagreement' build_final_disputes "$disputes_file"
assert_eq 'severity' "$(jq -r '.[0].kind_hint' "$disputes_file")" \
    'agreeing CONFIRMED classifications with different severities hint at a severity dispute'

CROSS_FINDINGS_OUTPUTS[gamma]="$cross_canonical"
assert_true 'dispute detection runs on agreeing cross-reviews' build_final_disputes "$disputes_file"
assert_eq '0' "$(jq 'length' "$disputes_file")" 'agreeing cross-reviews produce no dispute'

unset 'CROSS_FINDINGS_OUTPUTS[gamma]'
REVIEW_AGENTS=(alpha)

resolutions_prompt="$test_root/required-resolutions-prompt.md"
printf 'Prompt body\n' >"$resolutions_prompt"
printf '%s\n' '[{"dispute_id":"dispute:beta:beta:F-001","primary_ref":{"agent":"beta","source_id":"beta:F-001"},"kind_hint":"factual","conflicting_refs":[{"agent":"alpha","source_id":"alpha:C-001","classification":"CONFIRMED","severity":"P1"},{"agent":"gamma","source_id":"gamma:C-001","classification":"REJECTED","severity":null}]}]' >"$disputes_file"
append_required_resolutions_to_prompt "$resolutions_prompt" "$disputes_file"
assert_file_contains "$resolutions_prompt" '===== BEGIN REQUIRED RESOLUTIONS =====' \
    'the final prompt gets a required-resolutions block'
assert_file_contains "$resolutions_prompt" '"dispute_id":"dispute:beta:beta:F-001"' \
    'each detected dispute is listed as one compact JSON line'
assert_file_contains "$resolutions_prompt" 'exactly one resolution record per listed dispute' \
    'the block states the one-record-per-dispute rule'
printf '[]\n' >"$disputes_file"
printf 'Prompt body\n' >"$resolutions_prompt"
append_required_resolutions_to_prompt "$resolutions_prompt" "$disputes_file"
assert_file_contains "$resolutions_prompt" 'none' \
    'an empty dispute list is stated explicitly so the model emits no resolution records'
assert_true 'the resolution contract text names every record key' \
    grep -Fq -- 'dispute_id, primary_ref, conflicting_refs, final_source_id, dispute_kind, resolution_status, verification_method, command, observed, basis, basis_source, limitations' <<<"$FINAL_RESOLUTION_CONTRACT_BLOCK"

printf '%s\n' '[{"dispute_id":"dispute:beta:beta:F-001","primary_ref":{"agent":"beta","source_id":"beta:F-001"},"kind_hint":"factual","conflicting_refs":[{"agent":"alpha","source_id":"alpha:C-001","classification":"CONFIRMED","severity":"P1"},{"agent":"gamma","source_id":"gamma:C-001","classification":"REJECTED","severity":null}]}]' >"$disputes_file"
resolution_fixture="$test_dir/fixtures/final-resolution-valid.ndjson"
resolution_records="$test_root/resolution-records.json"
resolution_final_canonical="$test_root/resolution-final-canonical.json"
resolution_canonical="$test_root/resolutions-canonical.json"
jq -s '[.[] | select(.record == "resolution")]' "$resolution_fixture" >"$resolution_records"
jq -s '{findings: [.[] | select(.record == "finding")]}' "$resolution_fixture" >"$resolution_final_canonical"
assert_true 'a measured factual resolution covering its dispute is valid' \
    validate_final_resolutions "$resolution_records" "$resolution_final_canonical" "$disputes_file" "$resolution_canonical"
assert_eq 'ndjson-v1' "$(jq -r '.contract' "$resolution_canonical")" 'the resolutions sidecar records its contract'
assert_eq '1' "$(jq '.disputes | length' "$resolution_canonical")" 'the resolutions sidecar keeps the detected dispute list'
assert_eq '' "$(describe_resolution_validation_failure "$resolution_records" "$resolution_final_canonical" "$disputes_file")" \
    'a valid resolution set has no diagnostics'

uncertain_final_for_null="$test_root/resolution-final-uncertain-for-null.json"
jq '.findings[0].classification = "UNCERTAIN" | .findings[0].severity = null' "$resolution_final_canonical" >"$uncertain_final_for_null"

check_invalid_resolution() {
    local label=$1 filter=$2 expected_detail=$3
    local candidate="$test_root/resolution-${label}.json"
    jq "$filter" "$resolution_records" >"$candidate"
    assert_false "$label is rejected" \
        validate_final_resolutions "$candidate" "$resolution_final_canonical" "$disputes_file" "$test_root/resolution-${label}-canonical.json"
    assert_eq "$expected_detail" "$(describe_resolution_validation_failure "$candidate" "$resolution_final_canonical" "$disputes_file")" \
        "$label has a stable diagnostic"
}
enriched_refs="$test_root/resolution-enriched-refs.json"
jq '.[0].conflicting_refs = [{agent: "alpha", source_id: "alpha:C-001", classification: "CONFIRMED", severity: "P1"}, {agent: "gamma", source_id: "gamma:C-001", classification: "REJECTED", severity: null}]' \
    "$resolution_records" >"$enriched_refs"
assert_true 'conflicting refs copied with their listed classification and severity are accepted' \
    validate_final_resolutions "$enriched_refs" "$resolution_final_canonical" "$disputes_file" "$test_root/resolution-enriched-canonical.json"
assert_eq '[{"agent":"alpha","source_id":"alpha:C-001"},{"agent":"gamma","source_id":"gamma:C-001"}]' \
    "$(jq -c '.resolutions[0].conflicting_refs' "$test_root/resolution-enriched-canonical.json")" \
    'the canonical sidecar keeps only agent and source_id in conflicting refs'

split_final="$test_root/resolution-split-final.json"
jq '.findings[0].source_refs = [{agent: "alpha", source_id: "alpha:C-001"}] | .findings += [(.findings[0] | .source_id = "FINAL-002" | .source_refs = [{agent: "gamma", source_id: "gamma:C-001"}])]' \
    "$resolution_final_canonical" >"$split_final"
assert_true 'a resolution may name a final record that covers only part of the conflicting refs' \
    validate_final_resolutions "$resolution_records" "$split_final" "$disputes_file" "$test_root/resolution-split-canonical.json"
unrelated_final="$test_root/resolution-unrelated-final.json"
jq '.findings[0].source_refs = [{agent: "alpha", source_id: "alpha:C-777"}]' "$resolution_final_canonical" >"$unrelated_final"
assert_false 'a resolution may not name a final record that shares no conflicting ref' \
    validate_final_resolutions "$resolution_records" "$unrelated_final" "$disputes_file" "$test_root/resolution-unrelated-canonical.json"
assert_eq 'resolution[dispute:beta:beta:F-001].final_source_id' \
    "$(describe_resolution_validation_failure "$resolution_records" "$unrelated_final" "$disputes_file")" \
    'the diagnostic names the unlinked final record'

null_observed_uncertain="$test_root/resolution-null-observed.json"
jq '.[0].resolution_status = "uncertain" | .[0].observed = null | .[0].command = null | .[0].verification_method = "source"' "$resolution_records" >"$null_observed_uncertain"
assert_true 'an unresolved resolution may leave observed null' \
    validate_final_resolutions "$null_observed_uncertain" "$uncertain_final_for_null" "$disputes_file" "$test_root/resolution-null-observed-canonical.json"
check_invalid_resolution manual-factual '.[0].verification_method = "manual"' \
    'resolution[dispute:beta:beta:F-001].verification_method'
check_invalid_resolution command-without-observed '.[0].observed = ""' \
    'resolution[dispute:beta:beta:F-001].observed'
check_invalid_resolution resolved-without-observed '.[0].observed = null' \
    'resolution[dispute:beta:beta:F-001].observed'
check_invalid_resolution unknown-dispute '.[0].dispute_id = "dispute:beta:beta:F-999"' \
    'resolutions.missing[dispute:beta:beta:F-001], resolutions.unknown[dispute:beta:beta:F-999]'
check_invalid_resolution wrong-refs '.[0].conflicting_refs = [{agent: "alpha", source_id: "alpha:C-001"}]' \
    'resolution[dispute:beta:beta:F-001].conflicting_refs'
check_invalid_resolution wrong-final-link '.[0].final_source_id = "FINAL-404"' \
    'resolution[dispute:beta:beta:F-001].final_source_id'
check_invalid_resolution explicit-rule-without-source '.[0].basis = "explicit_repository_rule"' \
    'resolution[dispute:beta:beta:F-001].basis_source'
check_invalid_resolution shell-string-command '.[0].command = "grep -n changedBranch src/Changed.php"' \
    'resolution[dispute:beta:beta:F-001].command'
check_invalid_resolution not-applicable-factual '.[0].resolution_status = "not_applicable"' \
    'resolution[dispute:beta:beta:F-001].resolution_status, resolution[dispute:beta:beta:F-001].confirmed_over_unresolved_factual'

uncertain_resolution="$test_root/resolution-uncertain.json"
jq '.[0].resolution_status = "uncertain" | .[0].verification_method = "manual" | .[0].command = null | .[0].observed = ""' "$resolution_records" >"$uncertain_resolution"
assert_false 'a CONFIRMED finding over an unresolved factual dispute is rejected' \
    validate_final_resolutions "$uncertain_resolution" "$resolution_final_canonical" "$disputes_file" "$test_root/resolution-uncertain-canonical.json"
assert_eq 'resolution[dispute:beta:beta:F-001].confirmed_over_unresolved_factual' \
    "$(describe_resolution_validation_failure "$uncertain_resolution" "$resolution_final_canonical" "$disputes_file")" \
    'the diagnostic names the count-over-measurement violation'
uncertain_final="$test_root/resolution-uncertain-final.json"
jq '.findings[0].classification = "UNCERTAIN" | .findings[0].severity = null' "$resolution_final_canonical" >"$uncertain_final"
assert_true 'an UNCERTAIN finding over an unresolved factual dispute is valid' \
    validate_final_resolutions "$uncertain_resolution" "$uncertain_final" "$disputes_file" "$test_root/resolution-uncertain-ok-canonical.json"

inferred_resolution="$test_root/resolution-inferred.json"
jq '.[0].basis = "inferred_convention"' "$resolution_records" >"$inferred_resolution"
assert_false 'a P1 finding whose only basis is an inferred convention is rejected' \
    validate_final_resolutions "$inferred_resolution" "$resolution_final_canonical" "$disputes_file" "$test_root/resolution-inferred-canonical.json"
assert_eq 'resolution[dispute:beta:beta:F-001].inferred_convention_severity' \
    "$(describe_resolution_validation_failure "$inferred_resolution" "$resolution_final_canonical" "$disputes_file")" \
    'the diagnostic names the inferred-convention severity rule'

severity_disputes="$test_root/severity-disputes.json"
jq '.[0].kind_hint = "severity" | .[0].conflicting_refs[1].classification = "CONFIRMED" | .[0].conflicting_refs[1].severity = "P3"' "$disputes_file" >"$severity_disputes"
severity_resolution="$test_root/resolution-severity.json"
jq '.[0].dispute_kind = "severity" | .[0].resolution_status = "not_applicable" | .[0].verification_method = "manual" | .[0].command = null | .[0].observed = ""' "$resolution_records" >"$severity_resolution"
assert_true 'a severity-only dispute may be reconciled without a measurement' \
    validate_final_resolutions "$severity_resolution" "$resolution_final_canonical" "$severity_disputes" "$test_root/resolution-severity-canonical.json"

final_records="$test_root/final-records.json"
final_canonical="$test_root/final-canonical.json"
jq -n '{
    record: "finding", schema_version: 1, source_id: "FINAL-001",
    source_refs: [{agent: "alpha", source_id: "alpha:C-001"}],
    title: "Fixture final finding", claim: "The changed branch can fail.",
    anchor: {kind: "changed-line", file: "src/Changed.php", start: 10, "end": 10},
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

# A synthesizer that writes the contract's placeholder wording into the agent key
# ("cross-review-alpha" for "alpha") names a record that exists under exactly one
# owner. Correcting it is arithmetic on the supplied refs, not a decision.
final_prefixed_agent="$test_root/final-prefixed-agent.json"
final_normalized_agent="$test_root/final-normalized-agent.json"
jq '.[0].source_refs[0].agent = "cross-review-alpha" | .[0].contributing_agents = ["cross-review-alpha"]' \
    "$final_records" >"$final_prefixed_agent"
assert_false 'a mislabelled cross-review agent key fails validation untouched' \
    validate_final_ndjson_records "$final_prefixed_agent" "$test_root/final-prefixed-canonical.json" "$final_expected_refs"
assert_true 'an unambiguous source id repairs its agent key' \
    normalize_ndjson_source_ref_agents "$final_prefixed_agent" "$final_expected_refs" "$final_normalized_agent"
assert_eq 'alpha' "$(jq -r '.[0].source_refs[0].agent' "$final_normalized_agent")" \
    'the agent key is corrected to the single owner of that source id'
assert_eq 'alpha' "$(jq -r '.[0].contributing_agents | join(",")' "$final_normalized_agent")" \
    'contributing_agents follows the corrected source refs'
assert_true 'the corrected stream then passes validation' \
    validate_final_ndjson_records "$final_normalized_agent" "$test_root/final-normalized-canonical.json" "$final_expected_refs"

final_unknown_id="$test_root/final-unknown-id.json"
final_unknown_normalized="$test_root/final-unknown-normalized.json"
jq '.[0].source_refs[0].source_id = "alpha:C-999"' "$final_records" >"$final_unknown_id"
assert_true 'normalization runs over a stream it cannot repair' \
    normalize_ndjson_source_ref_agents "$final_unknown_id" "$final_expected_refs" "$final_unknown_normalized"
assert_eq 'alpha:C-999' "$(jq -r '.[0].source_refs[0].source_id' "$final_unknown_normalized")" \
    'an unknown source id is left alone rather than guessed at'

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
final_rejected_null_recommendation="$test_root/final-rejected-null-recommendation.json"
jq '.[0].classification = "REJECTED" | .[0].severity = null | .[0].failure_scenario = null | .[0].recommendation = null' "$final_records" >"$final_rejected_null_recommendation"
assert_true 'a rejected final claim may use a null recommendation' \
    validate_final_ndjson_records "$final_rejected_null_recommendation" "$test_root/final-rejected-null-recommendation-canonical.json" "$final_expected_refs"
final_confirmed_null_recommendation="$test_root/final-confirmed-null-recommendation.json"
jq '.[0].recommendation = null' "$final_records" >"$final_confirmed_null_recommendation"
assert_false 'a confirmed final finding still requires a recommendation' \
    validate_final_ndjson_records "$final_confirmed_null_recommendation" "$test_root/final-confirmed-null-recommendation-canonical.json" "$final_expected_refs"
final_confirmed_null_scenario="$test_root/final-confirmed-null-scenario.json"
jq '.[0].failure_scenario = null' "$final_records" >"$final_confirmed_null_scenario"
assert_false 'a confirmed final finding rejects a null failure scenario' \
    validate_final_ndjson_records "$final_confirmed_null_scenario" "$test_root/final-confirmed-null-canonical.json" "$final_expected_refs"
final_confirmed_empty_scenario="$test_root/final-confirmed-empty-scenario.json"
jq '.[0].failure_scenario = ""' "$final_records" >"$final_confirmed_empty_scenario"
assert_false 'a confirmed final finding still requires a failure scenario' \
    validate_final_ndjson_records "$final_confirmed_empty_scenario" "$test_root/final-confirmed-empty-canonical.json" "$final_expected_refs"

final_missing_feedback="$test_root/final-missing-feedback.ndjson"
jq -c '.[0] | del(.existing_feedback)' "$final_records" >"$final_missing_feedback"
jq -c '.[1]' "$final_records" >>"$final_missing_feedback"
assert_true 'a final finding missing only existing_feedback is eligible for repair' \
    build_final_repair_baseline "$final_missing_feedback" "$test_root/final-missing-feedback-baseline.json"
assert_eq 'unknown' "$(jq -r '.findings[0].existing_feedback.state' "$test_root/final-missing-feedback-baseline.json")" \
    'the final repair baseline records missing existing feedback as unknown'

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

# A final synthesis that stopped early is continued on the same terms as a
# cross-review, with one extra rule: a draft that already decided disputes is
# refused, because those decisions were made against an incomplete finding set.
final_continuation_refs="$test_root/final-continuation-refs.json"
jq '[.[0], (.[0] | .agent = "gamma" | .source_id = "gamma:C-001")]' "$final_expected_refs" \
    >"$final_continuation_refs"
final_truncated_draft="$test_root/final-truncated.ndjson"
jq -c '.[0]' "$final_records" >"$final_truncated_draft"
final_continuation_kept="$test_root/final-continuation-kept.ndjson"
final_continuation_pending="$test_root/final-continuation-pending.json"
assert_true 'a truncated final draft yields a continuation state' \
    build_continuation_state final "$final_truncated_draft" "$final_continuation_refs" \
        "$final_continuation_kept" "$final_continuation_pending"
assert_eq 'gamma:gamma:C-001' "$(jq -r '.[] | .agent + ":" + .source_id' "$final_continuation_pending")" \
    'the final continuation asks only for the unanswered cross-review refs'
final_resolution_draft="$test_root/final-truncated-with-resolution.ndjson"
{
    cat -- "$final_truncated_draft"
    printf '%s\n' '{"record":"resolution","schema_version":1,"dispute_id":"dispute:alpha:alpha:F-001"}'
} >"$final_resolution_draft"
assert_false 'a final draft that already resolved disputes is not continued' \
    build_continuation_state final "$final_resolution_draft" "$final_continuation_refs" \
        "$final_continuation_kept" "$final_continuation_pending"
build_continuation_state final "$final_truncated_draft" "$final_continuation_refs" \
    "$final_continuation_kept" "$final_continuation_pending"
assert_true 'an appended final continuation preserves the kept findings' \
    validate_continuation_prefix final "$final_continuation_kept" "$final_canonical"
final_changed_prefix="$test_root/final-continuation-changed.json"
jq '.findings[0].include_in_rejected_summary = true' "$final_canonical" >"$final_changed_prefix"
assert_false 'a final continuation may not change a kept rejection presentation decision' \
    validate_continuation_prefix final "$final_continuation_kept" "$final_changed_prefix"
final_continuation_prompt="$test_root/final-continuation-prompt.txt"
assert_true 'a final continuation prompt is written from the original phase prompt' \
    write_continuation_prompt final "$final_continuation_prompt" "$original_prompt" \
        "$final_continuation_kept" "$final_continuation_pending"
assert_file_contains "$final_continuation_prompt" 'INTERRUPTED FINAL SYNTHESIS' \
    'the final continuation prompt names its own phase'
assert_file_contains "$final_continuation_prompt" 'REQUIRED RESOLUTIONS' \
    'the final continuation prompt still demands the whole resolution set'

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

REVIEW_AGENTS=(alpha gamma)
CROSS_FINDINGS_OUTPUTS[gamma]="$gamma_cross_canonical"
DISPUTE_RESOLUTION_ENABLED=true
WORK_DIR=$test_root
REPORT_STEM=resolution-run
FINAL_FINDING_CONTRACT_MODE=ndjson-v1
processed_final="$test_root/processed-final.md"
cp -- "$resolution_fixture" "$processed_final"
assert_true 'a final stream with valid resolution records is processed' \
    process_final_ndjson_output "$processed_final"
assert_file_exists "$FINAL_PROCESSED_RESOLUTIONS_FILE" 'processing produces a resolutions sidecar candidate'
assert_eq '1' "$(jq '.resolutions | length' "$FINAL_PROCESSED_RESOLUTIONS_FILE")" \
    'the resolutions sidecar candidate holds the validated records'
assert_eq '1' "$(jq '.finding_count' "$FINAL_PROCESSED_FINDINGS_FILE")" \
    'resolution records are not counted as findings'
assert_file_contains "$processed_final" '<!-- review-pr:dispute-resolutions -->' \
    'the rendered final report carries the dispute-resolution marker'

DISPUTE_RESOLUTION_ENABLED=false
cp -- "$resolution_fixture" "$processed_final"
assert_false 'resolution records are rejected when the feature is disabled' \
    process_final_ndjson_output "$processed_final"
assert_eq 'unexpected_resolution_records' "$FINDING_CONTRACT_FAILURE_REASON" \
    'the disabled feature reports a stable reason'

DISPUTE_RESOLUTION_ENABLED=true
broken_resolution_stream="$test_root/broken-resolution.ndjson"
jq -c 'if .record == "resolution" then .verification_method = "manual" else . end' "$resolution_fixture" >"$broken_resolution_stream"
cp -- "$broken_resolution_stream" "$processed_final"
assert_false 'an unmeasured factual resolution fails final processing' \
    process_final_ndjson_output "$processed_final"
assert_eq 'dispute_resolution_validation_failed: resolution[dispute:beta:beta:F-001].verification_method' \
    "$FINDING_CONTRACT_FAILURE_REASON" 'final processing exposes the resolution diagnostic'

diagnostic_only_canonical="$test_root/diagnostic-only-final.json"
jq '.findings[0].source_id = "F-9" | .findings[0].evidence = ["CI check phpunit failed", "Pipeline status: pending"]' \
    "$FINAL_PROCESSED_FINDINGS_FILE" >"$diagnostic_only_canonical"
assert_eq 'finding[F-9]' "$(describe_diagnostic_only_findings "$diagnostic_only_canonical")" \
    'a confirmed finding whose only evidence is a failed or pending check is diagnostic-only'
jq '.findings[0].evidence += ["src/App/Service.php:42 throws on null"]' "$diagnostic_only_canonical" >"$diagnostic_only_canonical.tmp"
mv -- "$diagnostic_only_canonical.tmp" "$diagnostic_only_canonical"
assert_eq '' "$(describe_diagnostic_only_findings "$diagnostic_only_canonical")" \
    'one source-anchored evidence item clears the diagnostic-only check'
jq '.findings[0].classification = "UNCERTAIN" | .findings[0].severity = null | .findings[0].evidence = ["CI check phpunit failed"]' \
    "$diagnostic_only_canonical" >"$diagnostic_only_canonical.tmp"
mv -- "$diagnostic_only_canonical.tmp" "$diagnostic_only_canonical"
assert_eq '' "$(describe_diagnostic_only_findings "$diagnostic_only_canonical")" \
    'an uncertain claim may cite a check failure as its reason'
diagnostic_only_stream="$test_root/diagnostic-only.ndjson"
jq -c 'if .record == "finding" then .evidence = ["CI check phpunit failed", "Pipeline status: pending"] else . end' \
    "$resolution_fixture" >"$diagnostic_only_stream"
cp -- "$diagnostic_only_stream" "$processed_final"
assert_false 'a diagnostic-only confirmed finding fails final processing' \
    process_final_ndjson_output "$processed_final"
assert_eq 'diagnostic_only_finding: finding[FINAL-001]' "$FINDING_CONTRACT_FAILURE_REASON" \
    'final processing names the diagnostic-only finding'

resolution_baseline="$test_root/resolution-baseline.json"
assert_true 'a stream with resolution records produces a repair baseline' \
    build_final_repair_baseline "$resolution_fixture" "$resolution_baseline"
assert_eq '1' "$(jq '.resolutions | length' "$resolution_baseline")" 'the repair baseline preserves resolution decisions'
cp -- "$resolution_fixture" "$processed_final"
process_final_ndjson_output "$processed_final"
assert_true 'unchanged resolutions satisfy repair stability' \
    validate_final_repair_stability "$resolution_baseline" "$FINAL_PROCESSED_FINDINGS_FILE" "$FINAL_PROCESSED_RESOLUTIONS_FILE"
changed_resolutions="$test_root/changed-resolutions.json"
jq '.resolutions[0].resolution_status = "uncertain"' "$FINAL_PROCESSED_RESOLUTIONS_FILE" >"$changed_resolutions"
assert_false 'repair stability rejects a changed resolution decision' \
    validate_final_repair_stability "$resolution_baseline" "$FINAL_PROCESSED_FINDINGS_FILE" "$changed_resolutions"
assert_true 'a stream without resolution records still satisfies the two-argument stability check' \
    validate_final_repair_stability "$final_repair_baseline" "$final_canonical"
resolution_final_canonical_full=$FINAL_PROCESSED_FINDINGS_FILE
resolutions_canonical_full=$FINAL_PROCESSED_RESOLUTIONS_FILE
DISPUTE_RESOLUTION_ENABLED=false
REVIEW_AGENTS=(alpha)
unset 'CROSS_FINDINGS_OUTPUTS[gamma]'

FINALIZATION_LANGUAGE=EN
configure_finalization_language
rendered_with_resolutions="$test_root/final-with-resolutions.md"
assert_true 'the final renderer accepts a resolutions sidecar' \
    render_final_findings_markdown "$resolution_final_canonical_full" "$rendered_with_resolutions" "$resolutions_canonical_full"
assert_file_contains "$rendered_with_resolutions" '## Dispute resolutions' 'the English final report gets a dispute-resolution section'
assert_file_contains "$rendered_with_resolutions" '<!-- review-pr:dispute-resolutions -->' 'the section carries a language-independent marker'
assert_file_contains "$rendered_with_resolutions" '| `dispute:beta:beta:F-001` | factual | resolved | command |' \
    'each resolution is one table row with kind, status, and method'
assert_file_contains "$rendered_with_resolutions" '`grep -n changedBranch src/Changed.php`' \
    'a recorded argv command is shown joined by spaces inside code formatting'
FINALIZATION_LANGUAGE=UA
configure_finalization_language
render_final_findings_markdown "$resolution_final_canonical_full" "$rendered_with_resolutions" "$resolutions_canonical_full"
assert_file_contains "$rendered_with_resolutions" '## Вирішення суперечок' 'the Ukrainian final report localizes the heading'
assert_file_contains "$rendered_with_resolutions" '| `dispute:beta:beta:F-001` | factual | resolved | command |' \
    'enum values stay language-independent in the Ukrainian table'
FINALIZATION_LANGUAGE=EN
configure_finalization_language
render_final_findings_markdown "$final_canonical" "$rendered_with_resolutions"
assert_false 'a final report without resolutions has no dispute section' \
    grep -Fq -- 'review-pr:dispute-resolutions' "$rendered_with_resolutions"
assert_true 'a final report with the dispute table still passes the legacy structural validator' \
    validate_final_markdown "$test_root/processed-final.md"
render_final_findings_markdown "$resolution_final_canonical_full" "$rendered_with_resolutions" "$test_root/resolution-null-observed-canonical.json"
assert_file_contains "$rendered_with_resolutions" '| factual | uncertain | source | — | general_engineering |' \
    'a null observed value renders as a dash, not the word null'

assert_eq 'allowed' "$(measurement_command_policy '["rg","-n","needle","sample.txt"]')" 'a read-only search inside the checkout is allowed'
assert_eq 'allowed' "$(measurement_command_policy '["git","show","HEAD:sample.txt"]')" 'a read-only git subcommand is allowed'
assert_eq 'not_allowlisted' "$(measurement_command_policy '["docker","compose","exec","db","mysql"]')" 'runtime tools are not allow-listed'
assert_eq 'git_subcommand_not_allowlisted' "$(measurement_command_policy '["git","push","origin","main"]')" 'writing git subcommands are refused'
assert_eq 'unsafe_argument' "$(measurement_command_policy '["rg","--pre","sh","needle","sample.txt"]')" 'preprocessor options that execute programs are refused'
assert_eq 'unsafe_argument' "$(measurement_command_policy '["cat","../outside.txt"]')" 'parent-directory paths are refused'
assert_eq 'unsafe_argument' "$(measurement_command_policy '["cat","/etc/hosts"]')" 'absolute paths are refused'
assert_eq 'unsafe_argument' "$(measurement_command_policy '["git","-c","core.pager=sh","show","HEAD"]')" 'git configuration overrides are refused'
# The absolute-path guard read the whole argument, and an option carries its path
# after an equals sign, so `--output=/etc/x` began with a dash and passed. A
# measurement is supposed to read the checkout, and this one wrote anywhere the
# process could.
assert_eq 'unsafe_argument' "$(measurement_command_policy '["git","diff","--output=/tmp/written.txt"]')" \
    'an option that redirects output to an absolute path is refused'
assert_eq 'unsafe_argument' "$(measurement_command_policy '["git","diff","--output=inside.txt"]')" \
    'and it is refused for a relative path too, because a measurement never writes'
assert_eq 'unsafe_argument' "$(measurement_command_policy '["git","log","--output=../escape.txt"]')" \
    'the same option is refused on every git subcommand'
assert_eq 'unsafe_argument' "$(measurement_command_policy '["rg","--file=/etc/patterns"]')" \
    'an absolute path after an equals sign is refused whatever the option'
assert_eq 'allowed' "$(measurement_command_policy '["git","diff","--stat=200"]')" \
    'an option whose value is not a path is still allowed'
assert_eq 'allowed' "$(measurement_command_policy '["rg","--max-count=3","needle","sample.txt"]')" \
    'and so is an ordinary numeric option'
assert_eq 'empty_command' "$(measurement_command_policy '[]')" 'an empty command is refused'
assert_eq 'empty_command' "$(measurement_command_policy 'null')" 'a null command is refused'

measure_dir="$test_root/measure-checkout"
mkdir -p -- "$measure_dir/src"
printf '%s\n' 'first line' 'needle here token=ghp_redactiontestREDACTIONTEST0123456789ab end' >"$measure_dir/sample.txt"
printf '%s\n' 'function changedBranch() {}' >"$measure_dir/src/Changed.php"
HEAD_SHA=cafebabe00000000000000000000000000000000
measurement_json="$test_root/measurement.json"
assert_true 'an allow-listed measurement runs in the checkout' \
    run_measurement '["grep","-n","needle","sample.txt"]' "$measure_dir" "$measurement_json"
assert_eq 'true' "$(jq -r '.executed' "$measurement_json")" 'the measurement records that it executed'
assert_eq '0' "$(jq -r '.exit_status' "$measurement_json")" 'the measurement records the exit status'
assert_true 'the measurement keeps a stdout excerpt' grep -q 'needle here' <<<"$(jq -r '.stdout_excerpt' "$measurement_json")"
assert_false 'credential-like values are redacted from excerpts' grep -q 'ghp_redactiontest' <<<"$(jq -r '.stdout_excerpt' "$measurement_json")"
assert_true 'redaction leaves a marker' grep -q 'REDACTED' <<<"$(jq -r '.stdout_excerpt' "$measurement_json")"
assert_eq "$HEAD_SHA" "$(jq -r '.commit' "$measurement_json")" 'the measurement records the measured commit'
run_measurement '["grep","-n","absent","sample.txt"]' "$measure_dir" "$measurement_json"
assert_eq '1' "$(jq -r '.exit_status' "$measurement_json")" 'a non-zero exit status is recorded, not treated as an error'
run_measurement '["docker","ps"]' "$measure_dir" "$measurement_json"
assert_eq 'false' "$(jq -r '.executed' "$measurement_json")" 'a refused command is not executed'
assert_eq 'not_allowlisted' "$(jq -r '.skipped_reason' "$measurement_json")" 'a refused command records the policy reason'
long_output_dir="$test_root/measure-long"
mkdir -p -- "$long_output_dir"
head -c 6000 /dev/zero | tr '\0' 'x' >"$long_output_dir/long.txt"
run_measurement '["cat","long.txt"]' "$long_output_dir" "$measurement_json"
assert_eq '2000' "$(jq -r '.stdout_excerpt | length' "$measurement_json")" 'stdout excerpts are bounded'
assert_eq 'true' "$(jq -r '.stdout_truncated' "$measurement_json")" 'truncation is recorded'

EXECUTE_MEASUREMENTS_ENABLED=true
MEASUREMENT_WORKING_DIRECTORY=$measure_dir
measured_canonical="$test_root/resolutions-measured.json"
cp -- "$resolution_canonical" "$measured_canonical"
attach_measurements "$measured_canonical"
assert_eq 'true' "$(jq -r '.resolutions[0].measurement.executed' "$measured_canonical")" 'a resolution with an allow-listed command gets an executed measurement'
assert_eq '0' "$(jq -r '.resolutions[0].measurement.exit_status' "$measured_canonical")" 'the attached measurement carries the exit status'
assert_eq 'Line 10 calls changedBranch() before the guard, so the failure path is reachable.' \
    "$(jq -r '.resolutions[0].observed' "$measured_canonical")" 'the model claim in observed is left untouched'
MEASUREMENT_WORKING_DIRECTORY=''
cp -- "$resolution_canonical" "$measured_canonical"
attach_measurements "$measured_canonical"
assert_eq 'checkout_unavailable' "$(jq -r '.resolutions[0].measurement.skipped_reason' "$measured_canonical")" 'without a checkout the measurement is skipped with a reason'
EXECUTE_MEASUREMENTS_ENABLED=false
cp -- "$resolution_canonical" "$measured_canonical"
attach_measurements "$measured_canonical"
assert_eq 'false' "$(jq -r '.resolutions[0] | has("measurement")' "$measured_canonical")" 'measurements are not attached when execution is disabled'
EXECUTE_MEASUREMENTS_ENABLED=true
MEASUREMENT_WORKING_DIRECTORY=$measure_dir
cp -- "$resolution_canonical" "$measured_canonical"
attach_measurements "$measured_canonical"
render_final_findings_markdown "$resolution_final_canonical_full" "$rendered_with_resolutions" "$measured_canonical"
assert_file_contains "$rendered_with_resolutions" '| Measured |' 'the dispute table gains a Measured column when measurements exist'
assert_file_contains "$rendered_with_resolutions" '| exit 0 |' 'an executed measurement shows its exit status'
EXECUTE_MEASUREMENTS_ENABLED=false
MEASUREMENT_WORKING_DIRECTORY=''

diag_root="$test_root/diagnostics"
mkdir -p -- "$diag_root"
PR_REVIEW_THREADS_STATUS=partial
PR_REVIEW_THREADS_REASON=pagination_incomplete
PR_CHECK_RUNS_JSON='[{"name":"phpunit","status":"completed","conclusion":"failure"},{"name":"phpunit","status":"completed","conclusion":"failure"},{"name":"lint","status":"in_progress","conclusion":null},{"name":"docs","status":"completed","conclusion":"skipped"},{"name":"build","status":"completed","conclusion":"success"}]'
CHANGED_LINE_MAP_FILE="$diag_root/missing-map.json"
REFERENCE_ANCESTRY_STATUS=measurement_failed
RERUN_FINAL=true
MANIFEST_FILE="$diag_root/manifest.json"
jq -n '{attempt_failures: {primary: [], cross_review: ["beta attempt 1/2 (timeout after 5s)", "gamma attempt 1/2 (output token limit reached (32768 output tokens))"]},
        failures: {primary: [], cross_review: [], final: [], comparison: []},
        artifacts: {usage: {primary: {pi: "pi-usage.json"}, cross_review: {}, final: null, comparison: null}}}' >"$MANIFEST_FILE"
jq -n '{agent: "pi", phase: "primary review", pi_guard: {executed: 40, duplicates_blocked: 3, budget_blocked: 0, terminated: false}}' >"$diag_root/pi-usage.json"
WORK_DIR=$diag_root
FINAL_PROCESSED_RESOLUTIONS_FILE="$diag_root/resolutions.json"
jq '.resolutions[0].measurement = {executed: false, skipped_reason: "not_allowlisted"}' "$resolution_canonical" >"$FINAL_PROCESSED_RESOLUTIONS_FILE"
orchestrator_diagnostics="$diag_root/orchestrator.json"
assert_true 'orchestrator diagnostics are collected from the run state' \
    collect_orchestrator_diagnostics "$orchestrator_diagnostics"
assert_eq 'agent_attempt_output_limit,agent_attempt_timeout,changed_line_map_unavailable,checkout_unavailable,github_check_failed,github_check_pending,github_check_skipped,github_review_threads_partial,measurement_skipped,pi_guard_duplicates_blocked,repository_facts_measurement_failed' \
    "$(jq -r '[.[].type] | sort | join(",")' "$orchestrator_diagnostics")" \
    'every known orchestrator limitation becomes exactly one typed record'
assert_eq '1' "$(jq '[.[] | select(.type == "github_check_failed")] | length' "$orchestrator_diagnostics")" \
    'a duplicated failed check is recorded once'
assert_eq 'phpunit: failure' "$(jq -r '.[] | select(.type == "github_check_failed") | .detail' "$orchestrator_diagnostics")" \
    'a failed check names the check and its conclusion'
assert_eq 'cross-review' "$(jq -r '.[] | select(.type == "agent_attempt_timeout") | .phase' "$orchestrator_diagnostics")" \
    'an attempt failure keeps its phase'
assert_eq 'beta' "$(jq -r '.[] | select(.type == "agent_attempt_timeout") | .agent' "$orchestrator_diagnostics")" \
    'an attempt failure keeps its agent'
assert_eq 'dispute:beta:beta:F-001' "$(jq -r '.[] | select(.type == "measurement_skipped") | .refs[0]' "$orchestrator_diagnostics")" \
    'a skipped measurement references its dispute'
assert_eq 'pi' "$(jq -r '.[] | select(.type == "pi_guard_duplicates_blocked") | .agent' "$orchestrator_diagnostics")" \
    'guard counters from the published usage summary become a diagnostic'
PR_REVIEW_THREADS_STATUS=available
PR_CHECK_RUNS_JSON='[]'
REFERENCE_ANCESTRY_STATUS=measured
RERUN_FINAL=false
CHANGED_LINE_MAP_FILE="$test_dir/fixtures/changed-lines-valid.json"
FINAL_PROCESSED_RESOLUTIONS_FILE=''
jq -n '{attempt_failures: {primary: [], cross_review: []}, failures: {}, artifacts: {usage: {primary: {}, cross_review: {}}}}' >"$MANIFEST_FILE"
collect_orchestrator_diagnostics "$orchestrator_diagnostics"
assert_eq '0' "$(jq 'length' "$orchestrator_diagnostics")" 'a clean run has no orchestrator diagnostics'
WORK_DIR=$test_root

agg_root="$test_root/aggregation"
mkdir -p -- "$agg_root"
jq -n '{agent: "alpha", phase: "primary", findings: [{source_id: "A-1", verification_limitations: ["Database was not reachable."]}],
        verification_limitations: ["No staging environment was available"], positive_evidence: ["src/App/Service.php:10 validates the input before dispatch", "No issues were found in the migration order"]}' >"$agg_root/alpha.json"
jq -n '{agent: "beta", phase: "primary", findings: [{source_id: "B-1", verification_limitations: []}],
        verification_limitations: ["database was NOT reachable", "Docker socket access was denied"], positive_evidence: ["`src/App/Service.php:10` validates the input before dispatch."]}' >"$agg_root/beta.json"
jq -n '{agent: "alpha", phase: "cross-review", findings: [{source_id: "alpha:C-1", verification_limitations: ["The referenced upstream commit is unavailable locally"]}],
        verification_limitations: [], positive_evidence: []}' >"$agg_root/cross-alpha.json"
jq -n '{findings: [{source_id: "FINAL-1", verification_limitations: []}], verification_limitations: ["Migrations were not executed"], positive_evidence: ["down() removes the seeded rows in dependency order"]}' >"$agg_root/final.json"
REVIEW_AGENTS=(alpha beta)
PRIMARY_FINDINGS_OUTPUTS[alpha]="$agg_root/alpha.json"
PRIMARY_FINDINGS_OUTPUTS[beta]="$agg_root/beta.json"
CROSS_FINDINGS_OUTPUTS[alpha]="$agg_root/cross-alpha.json"
unset 'CROSS_FINDINGS_OUTPUTS[beta]'
reviewer_limitations="$agg_root/reviewers.json"
assert_true 'reviewer limitations aggregate across primary, cross-review, and final sidecars' \
    aggregate_reviewer_limitations "$agg_root/final.json" "$reviewer_limitations"
assert_eq '5' "$(jq 'length' "$reviewer_limitations")" 'limitations that differ only in case or trailing punctuation merge into one entry'
assert_eq 'alpha,beta' "$(jq -r '.[] | select(.text | test("not reachable"; "i")) | .agents | join(",")' "$reviewer_limitations")" \
    'a merged limitation keeps every contributing agent'
assert_eq 'A-1' "$(jq -r '.[] | select(.text | test("not reachable"; "i")) | .finding_refs[0].source_id' "$reviewer_limitations")" \
    'a finding-level limitation keeps its finding ref'
assert_eq 'final' "$(jq -r '.[] | select(.text | test("Migrations")) | .phases[0]' "$reviewer_limitations")" \
    'the final completion limitation is attributed to the final phase'
positive_evidence="$agg_root/positive.json"
assert_true 'positive evidence aggregates with provenance' \
    aggregate_positive_evidence "$agg_root/final.json" "$positive_evidence"
assert_eq '3' "$(jq 'length' "$positive_evidence")" 'positive evidence differing only in backticks and trailing punctuation merges into one entry'
assert_eq 'alpha,beta' "$(jq -r '.[0].agents | join(",")' "$positive_evidence")" 'the entry shared by two agents is ranked first'
assert_eq 'verified_safe' "$(jq -r '.[0].kind' "$positive_evidence")" 'evidence naming a file and line is labelled verified_safe'
assert_eq 'no_issue_found' "$(jq -r '.[] | select(.text | test("No issues")) | .kind' "$positive_evidence")" 'evidence without a file or symbol is labelled no_issue_found'
many_root="$agg_root/many"
mkdir -p -- "$many_root"
jq -n '{agent: "alpha", phase: "primary", findings: [], verification_limitations: [], positive_evidence: [range(0; 14) | "Item \(.) is fine"]}' >"$many_root/alpha.json"
PRIMARY_FINDINGS_OUTPUTS[alpha]="$many_root/alpha.json"
PRIMARY_FINDINGS_OUTPUTS[beta]="$agg_root/beta.json"
aggregate_positive_evidence "$agg_root/final.json" "$positive_evidence"
assert_eq '12' "$(jq 'length' "$positive_evidence")" 'positive evidence is capped at twelve entries'
REVIEW_AGENTS=(alpha)
unset 'PRIMARY_FINDINGS_OUTPUTS[beta]'

known_prompt="$agg_root/known-limitations-prompt.md"
printf 'Prompt body\n' >"$known_prompt"
printf '%s\n' '[{"type":"github_check_failed","scope":"run","phase":null,"agent":null,"detail":"phpunit: failure","refs":[]}]' >"$agg_root/known.json"
append_known_limitations_to_prompt "$known_prompt" "$agg_root/known.json"
assert_file_contains "$known_prompt" '===== BEGIN KNOWN LIMITATIONS =====' 'the final prompt gets a known-limitations block'
assert_file_contains "$known_prompt" '"type":"github_check_failed"' 'each orchestrator record is one compact JSON line'
assert_file_contains "$known_prompt" 'never a finding by itself' 'the block restates that limitations are not findings'
printf '[]\n' >"$agg_root/known.json"
printf 'Prompt body\n' >"$known_prompt"
append_known_limitations_to_prompt "$known_prompt" "$agg_root/known.json"
assert_file_contains "$known_prompt" 'none' 'an empty record list is stated explicitly'

diag_sidecar="$agg_root/final-diagnostics.json"
jq -n '{contract: "ndjson-v1", schema_version: 1, phase: "final-synthesis",
        orchestrator: [{type: "github_check_failed", scope: "run", phase: null, agent: null, detail: "phpunit: failure", refs: []},
                       {type: "agent_attempt_timeout", scope: "agent", phase: "cross-review", agent: "beta", detail: "beta attempt 1/2 (timeout after 5s)", refs: []}],
        reviewers: [{text: "Could not run the test suite", phases: ["primary"], agents: ["alpha", "beta"], finding_refs: [{agent: "alpha", source_id: "F-1"}]}],
        positive_evidence: [{text: "src/File.php:10 guards the null path", kind: "verified_safe", phases: ["primary"], agents: ["alpha"]}]}' >"$diag_sidecar"
diag_rendered="$agg_root/final-with-diagnostics.md"
assert_true 'the final renderer accepts a diagnostics sidecar' \
    render_final_findings_markdown "$final_canonical" "$diag_rendered" '' "$diag_sidecar"
assert_file_contains "$diag_rendered" '<!-- review-pr:verification-limitations -->' 'the limitations section carries its marker'
assert_file_contains "$diag_rendered" '## Verification limitations' 'the limitations section has the English heading'
assert_file_contains "$diag_rendered" '**CI check failed:** phpunit: failure' 'an orchestrator record renders its label and detail'
assert_file_contains "$diag_rendered" '(cross-review, beta)' 'an agent-scoped record names its phase and agent'
assert_file_contains "$diag_rendered" 'Could not run the test suite (alpha, beta) — `alpha:F-1`' 'a merged reviewer limitation lists its agents and finding refs'
assert_file_contains "$diag_rendered" '<!-- review-pr:positive-evidence -->' 'the positive-evidence section carries its marker'
assert_file_contains "$diag_rendered" '## Positive evidence' 'the positive-evidence section has the English heading'
assert_file_contains "$diag_rendered" 'src/File.php:10 guards the null path (alpha)' 'positive evidence lists its agents'
assert_true 'a final report with diagnostics sections passes the legacy structural validator' \
    validate_final_markdown "$diag_rendered"
FINALIZATION_LANGUAGE=UA
configure_finalization_language
render_final_findings_markdown "$final_canonical" "$diag_rendered" '' "$diag_sidecar"
assert_file_contains "$diag_rendered" '## Обмеження перевірки' 'the limitations heading is localized'
assert_file_contains "$diag_rendered" '## Позитивні докази' 'the positive-evidence heading is localized'
assert_file_contains "$diag_rendered" '**Перевірка CI не пройшла:** phpunit: failure' 'orchestrator labels are localized'
FINALIZATION_LANGUAGE=EN
configure_finalization_language
jq '.orchestrator = [] | .reviewers = [] | .positive_evidence = []' "$diag_sidecar" >"$agg_root/empty-diagnostics.json"
render_final_findings_markdown "$final_canonical" "$diag_rendered" '' "$agg_root/empty-diagnostics.json"
assert_false 'an empty diagnostics sidecar renders no limitations section' \
    grep -q 'review-pr:verification-limitations' "$diag_rendered"
assert_false 'an empty diagnostics sidecar renders no positive-evidence section' \
    grep -q 'review-pr:positive-evidence' "$diag_rendered"

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
replace_first_literal '"classification":null' '"classification":"CONFIRMED"' \
    <"$test_dir/fixtures/primary-findings-valid.ndjson" >"$classified"
assert_invalid_contract primary-classification 'schema_or_completeness_validation_failed: finding[F-001].classification' "$classified"

foreign_provenance="$test_root/foreign-provenance.ndjson"
replace_first_literal '"contributing_agents":["codex"]' '"contributing_agents":["codex","claude"]' \
    <"$test_dir/fixtures/primary-findings-valid.ndjson" >"$foreign_provenance"
assert_invalid_contract foreign-primary-provenance 'schema_or_completeness_validation_failed: finding[F-001].contributing_agents' "$foreign_provenance"

missing_thread_id="$test_root/missing-thread-id.ndjson"
replace_first_literal '"state":"new","thread_ids":[]' '"state":"confirmed-existing","thread_ids":[]' \
    <"$test_dir/fixtures/primary-findings-valid.ndjson" >"$missing_thread_id"
assert_invalid_contract missing-existing-thread-id 'schema_or_completeness_validation_failed: finding[F-001].existing_feedback' "$missing_thread_id"

preamble="$test_root/preamble-source.ndjson"
{
    printf '%s\n' 'Here is the requested review:'
    cat -- "$test_dir/fixtures/primary-findings-valid.ndjson"
} >"$preamble"
assert_invalid_contract prose-preamble invalid_json_line_1 "$preamble"

# A JSON-looking line that does not parse is not one accident but two. The model
# either stopped mid-token, or finished the record and mis-punctuated it -- one
# stray bracket on the longest record of a stream whose other forty-five were
# perfect. The first cannot be put back without inventing what was cut; the
# second is exactly what the repair pass exists for.
assert_true 'a record the model finished writing is recognised as terminated' \
    ndjson_line_is_terminated_record '{"record":"finding","recommendation":"text."]}'
assert_false 'a record torn off mid-token is not' \
    ndjson_line_is_terminated_record '{"record":"finding","claim":"half a sen'
assert_false 'and neither is transport prose' \
    ndjson_line_is_terminated_record 'Here is the requested review:'

baseline_valid=$(head -n 1 -- "$test_dir/fixtures/primary-findings-valid.ndjson")
baseline_complete=$(tail -n 1 -- "$test_dir/fixtures/primary-findings-valid.ndjson")
baseline_dirty='{"record":"finding","schema_version":1,"source_id":"F-009","recommendation":"text."],"classification":null}'
baseline_torn='{"record":"finding","schema_version":1,"source_id":"F-009","claim":"half a sen'

printf '%s\n%s\n%s\n' "$baseline_valid" "$baseline_dirty" "$baseline_complete" >"$test_root/baseline-dirty.ndjson"
printf '%s\n%s\n%s\n' "$baseline_valid" "$baseline_torn" "$baseline_complete" >"$test_root/baseline-torn.ndjson"
REPORT_STEM=fixture-baseline
assert_true 'a stream with one mis-punctuated record still yields a repair baseline' \
    build_primary_repair_baseline "$test_root/baseline-dirty.ndjson" "$test_root/baseline-dirty.md"
assert_eq 1 "$NDJSON_BASELINE_DIRTY_RECORDS" \
    'and the record it could not read is counted, not silently forgotten'
assert_false 'a stream torn off mid-record is still refused outright' \
    build_primary_repair_baseline "$test_root/baseline-torn.ndjson" "$test_root/baseline-torn.md"

# Salvage: the step before a phase is abandoned. Every record is put to the same
# contract on its own, and whatever stands is kept. The run has already been paid
# for by the time this matters, so refusing to publish what survived would throw
# away the good work along with the bad.
salvage_input="$test_root/salvage-primary.ndjson"
printf '%s\n%s\n%s\n' "$baseline_valid" "$baseline_dirty" "$baseline_complete" >"$salvage_input"
REPORT_STEM=fixture-salvage
PRIMARY_RAW_OUTPUTS[codex]="$test_root/fixture-salvage-codex-raw.ndjson"
PRIMARY_FINDINGS_OUTPUTS[codex]="$test_root/fixture-salvage-codex-findings.json"
assert_false 'an unreadable record still fails the contract on the ordinary path' \
    process_primary_ndjson_output "$salvage_input" codex
assert_eq invalid_json_line_2 "$FINDING_CONTRACT_FAILURE_REASON" \
    'and names the line it could not read'

cp -- "$test_dir/fixtures/primary-findings-valid.ndjson" "$salvage_input"
python3 - "$salvage_input" <<'PYTHON'
import sys
path = sys.argv[1]
lines = [line for line in open(path, encoding='utf-8').read().split('\n') if line.strip()]
# F-002 keeps every key but loses its severity, so it fails the schema while the
# rest of the stream stays perfectly good.
lines = [line.replace('"severity":"P2"', '"severity":"catastrophic"') if '"F-002"' in line else line
         for line in lines]
open(path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PYTHON
REPORT_STEM=fixture-salvage-schema
PRIMARY_RAW_OUTPUTS[codex]="$test_root/fixture-salvage-schema-codex-raw.ndjson"
PRIMARY_FINDINGS_OUTPUTS[codex]="$test_root/fixture-salvage-schema-codex-findings.json"
assert_false 'a record that breaks the schema fails the ordinary path too' \
    process_primary_ndjson_output "$salvage_input" codex
assert_true 'but salvage keeps the records that stand on their own' \
    run_ndjson_salvage primary codex "$salvage_input"
assert_eq 1 "$(jq '.findings | length' "${PRIMARY_FINDINGS_OUTPUTS[codex]}")" \
    'the salvaged artifact holds the finding that was well formed'
assert_eq F-001 "$(jq -r '.findings[0].source_id' "${PRIMARY_FINDINGS_OUTPUTS[codex]}")" \
    'and it is the one the model wrote correctly'
assert_eq F-002 "${NDJSON_SALVAGE_DROPPED_IDS[0]}" \
    'the dropped finding is named, so the loss can be read back'
assert_eq 1 "$(jq '.finding_count' "${PRIMARY_FINDINGS_OUTPUTS[codex]}")" \
    'and the terminal count is corrected to what the stream actually carries'

printf 'not a record at all\n' >"$test_root/salvage-empty.ndjson"
REPORT_STEM=fixture-salvage-empty
PRIMARY_RAW_OUTPUTS[codex]="$test_root/fixture-salvage-empty-codex-raw.ndjson"
PRIMARY_FINDINGS_OUTPUTS[codex]="$test_root/fixture-salvage-empty-codex-findings.json"
assert_false 'salvage refuses when nothing in the stream survives' \
    run_ndjson_salvage primary codex "$test_root/salvage-empty.ndjson"

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
