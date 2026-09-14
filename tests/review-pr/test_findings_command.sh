#!/usr/bin/env bash
# The findings subcommand hands a fixing agent the actionable part of a finished
# review as JSON, reading only what the orchestrator already published.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

suite_root=$(portable_mktemp_dir review-pr-findings)
trap 'rm -rf -- "$suite_root"' EXIT

reviews="$suite_root/reviews"
checkout="$suite_root/checkout"
config="$suite_root/config.json"
review_dir="$reviews/example-repository/28958-task-branch"
mkdir -p -- "$checkout" "$review_dir/work"

jq -n --arg checkout "$checkout" --arg reviews "$reviews" '{
    agents: {
        alpha: {"label": "Alpha", enabled: true, model: "mock-alpha", effort: "low"},
        beta: {"label": "Beta", enabled: true, model: "mock-beta", effort: "low"}
    },
    reviewers: ["alpha", "beta"],
    synthesizer: "alpha",
    default_repository: "fixture",
    repositories: {fixture: {github: "example/repository", checkout: $checkout}},
    reviews_directory: $reviews,
    language: "EN",
    finalization: {model: "mock-final", effort: "low"},
    status: {mode: "log", color: "never", refresh_interval_seconds: 1, log_interval_seconds: 30, show_pid: false},
    execution: {max_concurrency: 2, retry: {max_attempts: 1, delay_seconds: 0}}
}' >"$config"

# One published final sidecar per run, in the per-run working directory.
write_final_findings() {
    local run=$1
    local title=$2
    local run_dir="$review_dir/work/$run"
    mkdir -p -- "$run_dir"
    jq -n --arg run "$run" --arg title "$title" '{
        schema_version: 1, contract: "ndjson-v1", phase: "final-synthesis", agent: "alpha",
        finding_count: 4, summary: "Fixture synthesis.", verification_limitations: [], positive_evidence: [],
        findings: [
            {record: "finding", schema_version: 1, source_id: "syn-pr-level", classification: "CONFIRMED",
             severity: "P2", category: "testing", title: "Missing regression test",
             claim: "The changed branch has no test.", failure_scenario: "A regression ships unnoticed.",
             recommendation: "Add a test for the changed branch.",
             anchor: {kind: "pr-level", file: null, start: null, end: null},
             evidence: ["No test covers it."], verification_limitations: ["Could not run the suite."],
             include_in_rejected_summary: false, contributing_agents: ["beta"], source_refs: [], primary_refs: [],
             existing_feedback: {state: "new", thread_ids: []}},
            {record: "finding", schema_version: 1, source_id: "syn-confirmed", classification: "CONFIRMED",
             severity: "P1", category: "correctness", title: $title,
             claim: "The changed branch can fail.", failure_scenario: "The request reaches it.",
             recommendation: "Correct the changed branch.",
             anchor: {kind: "changed-line", file: "src/Changed.php", start: 10, end: 10},
             evidence: ["The changed line confirms it."], verification_limitations: [],
             include_in_rejected_summary: false, contributing_agents: ["beta"], source_refs: [], primary_refs: [],
             existing_feedback: {state: "new", thread_ids: []}},
            {record: "finding", schema_version: 1, source_id: "syn-uncertain", classification: "UNCERTAIN",
             severity: null, category: "correctness", title: "Unverified claim",
             claim: "It might fail.", failure_scenario: null, recommendation: "Reproduce first.",
             anchor: {kind: "changed-line", file: "src/Changed.php", start: 11, end: 11},
             evidence: ["Could not measure."], verification_limitations: ["No runtime access."],
             include_in_rejected_summary: false, contributing_agents: ["beta"], source_refs: [], primary_refs: [],
             existing_feedback: {state: "new", thread_ids: []}},
            {record: "finding", schema_version: 1, source_id: "syn-rejected", classification: "REJECTED",
             severity: null, category: "style", title: "Refuted claim",
             claim: "It looks wrong.", failure_scenario: null, recommendation: null,
             anchor: {kind: "changed-line", file: "src/Changed.php", start: 12, end: 12},
             evidence: ["The premise does not hold."], verification_limitations: [],
             include_in_rejected_summary: true, contributing_agents: ["beta"], source_refs: [], primary_refs: [],
             existing_feedback: {state: "new", thread_ids: []}}
        ]
    }' >"$run_dir/28958-task-branch-${run}-final-findings.json"
}

write_final_findings 20260101-120000-CET 'Older run finding'
write_final_findings 20260914-120000-CEST 'Newest run finding'

run_findings() {
    "$repo_root/bin/review-pr" --config "$config" findings "$@" 28958
}

output="$suite_root/out.json"
run_findings >"$output" 2>"$suite_root/err.txt" || fail "findings failed: $(cat "$suite_root/err.txt")"

assert_eq '20260914-120000-CEST' "$(jq -r '.run' "$output")" \
    'the newest run is reported by default'
assert_eq '28958' "$(jq -r '.pr_number | tostring' "$output")" \
    'the exported set names its pull request'
assert_eq 'syn-confirmed syn-pr-level' \
    "$(jq -r '[.findings[].id] | join(" ")' "$output")" \
    'only confirmed findings are exported, anchored ones before pr-level ones'
assert_eq 'Newest run finding' "$(jq -r '.findings[0].title' "$output")" \
    'the newest run supplies the content'
assert_eq 'src/Changed.php 10' \
    "$(jq -r '.findings[0] | .anchor.file + " " + (.anchor.start | tostring)' "$output")" \
    'an anchored finding carries its exact file and line'
assert_eq 'null' "$(jq -r '.findings[1].anchor.file' "$output")" \
    'a pr-level finding is kept with an empty anchor instead of being dropped'
assert_eq 'Could not run the suite.' "$(jq -r '.findings[1].verification_limitations[0]' "$output")" \
    'what could not be verified travels with the finding'
assert_false 'the export omits provenance a fixing agent cannot use' \
    grep -q 'primary_refs' "$output"

run_findings --include uncertain >"$output" 2>"$suite_root/err.txt" \
    || fail "findings --include uncertain failed: $(cat "$suite_root/err.txt")"
assert_eq 'syn-confirmed syn-uncertain syn-pr-level' \
    "$(jq -r '[.findings[].id] | join(" ")' "$output")" \
    'uncertain findings are added on request'

run_findings --include all >"$output" 2>"$suite_root/err.txt" \
    || fail "findings --include all failed: $(cat "$suite_root/err.txt")"
assert_eq '4' "$(jq -r '.findings | length' "$output")" \
    'the full set includes refuted claims'

run_findings --run 20260101-120000-CET >"$output" 2>"$suite_root/err.txt" \
    || fail "findings --run failed: $(cat "$suite_root/err.txt")"
assert_eq '20260101-120000-CET' "$(jq -r '.run' "$output")" 'an explicit run is honoured'
assert_eq 'Older run finding' "$(jq -r '.findings[0].title' "$output")" \
    'the selected run supplies the content'

assert_false 'an unknown run is refused instead of falling back to another one' \
    "$repo_root/bin/review-pr" --config "$config" findings --run 20250101-000000-CET 28958
assert_false 'an unknown include scope is refused' \
    "$repo_root/bin/review-pr" --config "$config" findings --include everything 28958
assert_false 'a pull request without a structured final review is refused' \
    "$repo_root/bin/review-pr" --config "$config" findings 28999

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
