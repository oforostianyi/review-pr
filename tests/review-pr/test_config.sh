#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

test_root=$(portable_mktemp_dir review-pr-config)
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p -- "$test_root/repository" "$test_root/reviews"

config_file="$test_root/config.json"
jq -n \
    --arg repository "$test_root/repository" \
    --arg reviews "$test_root/reviews" \
    --arg runner "$test_dir/mock-agent-runner.sh" \
    '{
        agents: {
            alpha: {label: "Alpha", enabled: true, model: "mock-alpha", effort: "", runner: $runner},
            beta: {label: "Beta", enabled: true, model: "mock-beta", effort: "", runner: $runner},
            paused: {label: "Paused", enabled: false, model: "", effort: "", runner: $runner}
        },
        reviewers: ["alpha", "beta", "paused"],
        synthesizer: "alpha",
        default_repository: "fixture",
        repositories: {
            fixture: {
                github: "example/repository",
                checkout: $repository,
                profile: "fixture"
            }
        },
        profiles: {
            fixture: {
                skills: {alpha: "", beta: "php-code-review"}
            }
        },
        reviews_directory: $reviews,
        language: "EN",
        languages: {primary: "", cross_review: "UA", final: "EN"},
        finalization: {model: "mock-small", effort: ""},
        reporting: {comparison_sections: {cross_review: "none", final: "standalone"}},
        status: {mode: "log", color: "never", refresh_interval_seconds: 1, log_interval_seconds: 30, show_pid: false},
        execution: {max_concurrency: 1, retry: {max_attempts: 2, delay_seconds: 0}}
    }' >"$config_file"

before_checksum=$(cksum "$config_file")
show_output="$test_root/show-config.txt"
"$repo_root/bin/review-pr" --config "$config_file" --show-config >"$show_output"
after_checksum=$(cksum "$config_file")

assert_eq "$before_checksum" "$after_checksum" 'configuration validation does not modify the source file'
assert_file_contains "$show_output" 'Active review agents: alpha beta' 'disabled agents are excluded without deleting their config'
assert_file_contains "$show_output" 'Disabled review agents: paused' 'disabled agent remains visible in diagnostics'
assert_file_contains "$show_output" 'Primary review language: EN (English)' 'global language is inherited by the primary phase'
assert_file_contains "$show_output" 'Cross-review language: UA (Ukrainian)' 'phase language overrides the global language'
assert_file_contains "$show_output" 'alpha: skill=' 'empty optional skill configuration is accepted'
assert_file_contains "$show_output" 'Primary finding contract: markdown' 'Markdown remains the backward-compatible primary contract default'

ndjson_config="$test_root/ndjson.json"
ndjson_output="$test_root/ndjson-show-config.txt"
jq '.reporting.finding_contract = {primary: "ndjson-v1"}' "$config_file" >"$ndjson_config"
"$repo_root/bin/review-pr" --config "$ndjson_config" --show-config >"$ndjson_output"
assert_file_contains "$ndjson_output" 'Primary finding contract: ndjson-v1' 'ndjson-v1 can be enabled explicitly for primary reviews'

invalid_config="$test_root/invalid.json"
jq '.reviewers = ["alpha"]' "$config_file" >"$invalid_config"
if "$repo_root/bin/review-pr" --config "$invalid_config" --show-config >/dev/null 2>&1; then
    fail 'configuration with fewer than two active reviewers must fail'
fi
pass 'configuration with fewer than two active reviewers is rejected'

invalid_contract_config="$test_root/invalid-contract.json"
jq '.reporting.finding_contract = {primary: "yaml"}' "$config_file" >"$invalid_contract_config"
if "$repo_root/bin/review-pr" --config "$invalid_contract_config" --show-config >/dev/null 2>&1; then
    fail 'configuration with an unsupported primary finding contract must fail'
fi
pass 'unsupported primary finding contract is rejected'

fallback_contract_config="$test_root/fallback-contract.json"
jq '.reporting.finding_contract = {primary: "ndjson-v1", fallback: "markdown"}' "$config_file" >"$fallback_contract_config"
if "$repo_root/bin/review-pr" --config "$fallback_contract_config" --show-config >/dev/null 2>&1; then
    fail 'finding contract must not accept a silent fallback setting'
fi
pass 'silent finding-contract fallback configuration is rejected'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
