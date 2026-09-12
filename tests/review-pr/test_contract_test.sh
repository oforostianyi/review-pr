#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

test_root=$(portable_mktemp_dir review-pr-contract-test)
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p -- "$test_root/reviews" "$test_root/bin"
ln -s "$test_dir/fake-codex.sh" "$test_root/bin/codex"

config_file="$test_root/config.json"
jq -n \
    --arg reviews "$test_root/reviews" \
    --arg runner "$test_dir/mock-agent-runner.sh" \
    '{
        agents: {
            alpha: {label: "Alpha", enabled: true, model: "mock-alpha", effort: "low", runner: $runner},
            beta: {label: "Beta", enabled: true, model: "mock-beta", effort: "medium", command: [$runner]},
            paused: {label: "Paused", enabled: false, model: "mock-paused", effort: "", runner: $runner},
            codex: {label: "Codex", enabled: false, model: "mock-codex", effort: "low"}
        },
        reviewers: ["alpha", "beta"],
        synthesizer: "alpha",
        default_repository: "fixture",
        repositories: {
            fixture: {github: "example/repository", checkout: "/repository/that/does/not/exist"}
        },
        reviews_directory: $reviews,
        language: "EN",
        finalization: {model: "mock-final", effort: "low"},
        reporting: {comparison_sections: {cross_review: "none", final: "standalone"}},
        status: {mode: "off", color: "never", refresh_interval_seconds: 1, log_interval_seconds: 30, show_pid: false},
        execution: {max_concurrency: 1, retry: {max_attempts: 1, delay_seconds: 0}}
    }' >"$config_file"

all_output="$test_root/all"
REVIEW_PR_MOCK_BEHAVIOR=contract-valid \
    "$repo_root/bin/review-pr" --config "$config_file" contract-test \
        --agent alpha --phase all --output "$all_output" >"$test_root/all.stdout" 2>"$test_root/all.stderr"

if [[ ! -s "$all_output/summary.json" ]]; then
    printf 'contract-test produced no summary; stderr follows:\n' >&2
    cat -- "$test_root/all.stderr" >&2
fi
assert_eq true "$(jq -r '.passed' "$all_output/summary.json")" \
    'contract test passes all three structured phases'
assert_eq 3 "$(jq -r '.results | length' "$all_output/summary.json")" \
    'one selected agent produces three contract results'
assert_eq 'primary,cross,final' "$(jq -r '[.results[].phase] | join(",")' "$all_output/summary.json")" \
    'contract phases execute in deterministic order'
assert_eq mock-alpha "$(jq -r '.results[0].model' "$all_output/summary.json")" \
    'summary records the configured model'
assert_eq low "$(jq -r '.results[0].effort' "$all_output/summary.json")" \
    'summary records the configured effort'
assert_eq mock-final "$(jq -r '.results[2].model' "$all_output/summary.json")" \
    'the configured synthesizer final contract uses the finalization model'

for phase in primary cross final; do
    assert_file_exists "$all_output/alpha-${phase}-prompt.txt" \
        "${phase} contract prompt is preserved"
    assert_file_exists "$all_output/alpha-${phase}-raw.ndjson" \
        "${phase} raw model output is preserved"
    assert_file_exists "$all_output/alpha-${phase}-findings.json" \
        "${phase} canonical findings are preserved"
    assert_file_exists "$all_output/alpha-${phase}.md" \
        "${phase} deterministic Markdown rendering is preserved"
    assert_file_exists "$all_output/alpha-${phase}-usage.json" \
        "${phase} usage metadata is preserved"
done
assert_eq primary "$(jq -r '.phase' "$all_output/alpha-primary-findings.json")" \
    'primary fixture is validated by the primary canonicalizer'
assert_eq cross-review "$(jq -r '.phase' "$all_output/alpha-cross-findings.json")" \
    'cross fixture is validated by the cross canonicalizer'
assert_eq final-synthesis "$(jq -r '.phase' "$all_output/alpha-final-findings.json")" \
    'final fixture is validated by the final canonicalizer'
assert_file_contains "$all_output/alpha-final.md" '# Code Review: fixture contract test' \
    'final fixture passes through the deterministic final renderer'

default_output="$test_root/default"
REVIEW_PR_MOCK_BEHAVIOR=contract-valid \
    "$repo_root/bin/review-pr" --config "$config_file" contract-test \
        --phase primary --output "$default_output" >/dev/null 2>"$test_root/default.stderr"
assert_eq 2 "$(jq -r '.results | length' "$default_output/summary.json")" \
    'default selection tests enabled reviewers and de-duplicates the synthesizer'
assert_eq 'alpha,beta' "$(jq -r '[.results[].agent] | join(",")' "$default_output/summary.json")" \
    'runner and configured-command agents share the contract-test path'

paused_output="$test_root/paused"
REVIEW_PR_MOCK_BEHAVIOR=contract-valid \
    "$repo_root/bin/review-pr" --config "$config_file" contract-test \
        --agent paused --phase primary --output "$paused_output" >/dev/null 2>"$test_root/paused.stderr"
assert_eq paused "$(jq -r '.results[0].agent' "$paused_output/summary.json")" \
    'an explicitly selected configured agent can be tested while disabled'

codex_output="$test_root/codex"
PATH="$test_root/bin:$PATH" \
    "$repo_root/bin/review-pr" --config "$config_file" contract-test \
        --agent codex --phase primary --output "$codex_output" >/dev/null 2>"$test_root/codex.stderr"
assert_eq true "$(jq -r '.passed' "$codex_output/summary.json")" \
    'built-in Codex contract testing bypasses only the Git repository preflight'

failed_output="$test_root/failed"
if REVIEW_PR_MOCK_BEHAVIOR=invalid \
    "$repo_root/bin/review-pr" --config "$config_file" contract-test \
        --agent alpha --phase primary --output "$failed_output" >"$test_root/failed.stdout" 2>"$test_root/failed.stderr"; then
    fail 'malformed contract output must fail the command'
fi
pass 'malformed contract output fails the command'
assert_eq false "$(jq -r '.passed' "$failed_output/summary.json")" \
    'failed contract result is recorded in the summary'
assert_file_exists "$failed_output/alpha-primary-raw.ndjson" \
    'failed raw output is retained for diagnosis'
assert_file_not_exists "$failed_output/alpha-primary-findings.json" \
    'failed output is not mistaken for canonical findings'

if REVIEW_PR_MOCK_BEHAVIOR=contract-valid \
    "$repo_root/bin/review-pr" --config "$config_file" contract-test \
        --agent alpha --phase primary --output "$all_output" >/dev/null 2>&1; then
    fail 'contract test must not overwrite an existing artifact directory'
fi
pass 'contract test refuses to overwrite an existing artifact directory'

if "$repo_root/bin/review-pr" --config "$config_file" contract-test \
    --agent missing --phase primary --output "$test_root/missing" >/dev/null 2>&1; then
    fail 'unknown contract-test agent must be rejected'
fi
pass 'unknown contract-test agent is rejected'

printf 'Contract-test assertions: %s\n' "$TEST_ASSERTIONS"
