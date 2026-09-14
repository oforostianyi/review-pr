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
            alpha: {"label": "Alpha", enabled: true, model: "mock-alpha", effort: "", timeout_seconds: 2700, runner: $runner},
            beta: {"label": "Beta", enabled: true, model: "mock-beta", effort: "", runner: $runner},
            paused: {"label": "Paused", enabled: false, model: "", effort: "", runner: $runner},
            pi: {"label": "Pi", enabled: false, model: "local-model", effort: "", max_tool_calls: 400}
        },
        reviewers: ["alpha", "beta", "paused", "pi"],
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
assert_file_contains "$show_output" 'Cross-review finding contract: markdown' 'Markdown remains the backward-compatible cross-review contract default'
assert_file_contains "$show_output" 'Final finding contract: markdown' 'Markdown remains the backward-compatible final contract default'
assert_file_contains "$show_output" 'timeout=45m\ 00s' 'configured agent timeout is visible in diagnostics'
assert_file_contains "$show_output" 'pi: label=Pi model=local-model effort='"'"''"'"' timeout=disabled max_tool_calls=400' \
    'configured Pi tool-call budget is visible in diagnostics'
assert_file_contains "$show_output" 'alpha: label=Alpha model=mock-alpha effort='"'"''"'"' timeout=45m\ 00s max_tool_calls=unlimited' \
    'agents without a tool-call budget report it as unlimited'

pi_thinking_config="$test_root/pi-thinking.json"
pi_thinking_output="$test_root/pi-thinking-show-config.txt"
jq '.agents.pi.enabled = true | .agents.pi.effort = "high" | .synthesizer = "pi" | .finalization.effort = "xhigh"' "$config_file" >"$pi_thinking_config"
# Enabling Pi makes --show-config require the pi command; an inert stand-in suffices here.
mkdir -p -- "$test_root/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "--append-system-prompt <text>" "--thinking <level>"\n' >"$test_root/bin/pi"
chmod 0755 "$test_root/bin/pi"
PATH="$test_root/bin:$PATH" "$repo_root/bin/review-pr" --config "$pi_thinking_config" --show-config >"$pi_thinking_output" 2>&1 \
    || fail "a Pi thinking level must be accepted as effort: $(tail -n 2 "$pi_thinking_output")"
assert_file_contains "$pi_thinking_output" "pi: label=Pi model=local-model effort=high" \
    'the Pi thinking level is shown as the agent effort'
assert_file_contains "$pi_thinking_output" 'Final effort: xhigh (finalization)' \
    'the finalization thinking level overrides the Pi agent level'
invalid_pi_thinking_config="$test_root/invalid-pi-thinking.json"
jq '.agents.pi.effort = "extreme"' "$config_file" >"$invalid_pi_thinking_config"
if "$repo_root/bin/review-pr" --config "$invalid_pi_thinking_config" --show-config >/dev/null 2>&1; then
    fail 'an unknown Pi thinking level must fail validation'
fi
pass 'an unknown Pi thinking level is rejected'

invalid_budget_agent_config="$test_root/invalid-budget-agent.json"
jq '.agents.alpha.max_tool_calls = 400' "$config_file" >"$invalid_budget_agent_config"
if "$repo_root/bin/review-pr" --config "$invalid_budget_agent_config" --show-config >/dev/null 2>&1; then
    fail 'max_tool_calls must be rejected for agents that cannot enforce it'
fi
pass 'max_tool_calls is rejected for agents other than pi'

invalid_budget_value_config="$test_root/invalid-budget-value.json"
jq '.agents.pi.max_tool_calls = 2.5' "$config_file" >"$invalid_budget_value_config"
if "$repo_root/bin/review-pr" --config "$invalid_budget_value_config" --show-config >/dev/null 2>&1; then
    fail 'fractional max_tool_calls must fail validation'
fi
pass 'fractional max_tool_calls is rejected'

invalid_timeout_config="$test_root/invalid-timeout.json"
jq '.agents.alpha.timeout_seconds = -1' "$config_file" >"$invalid_timeout_config"
if "$repo_root/bin/review-pr" --config "$invalid_timeout_config" --show-config >/dev/null 2>&1; then
    fail 'negative agent timeout must fail validation'
fi
pass 'negative agent timeout is rejected'

ndjson_config="$test_root/ndjson.json"
ndjson_output="$test_root/ndjson-show-config.txt"
jq '.reporting.finding_contract = {primary: "ndjson-v1"}' "$config_file" >"$ndjson_config"
"$repo_root/bin/review-pr" --config "$ndjson_config" --show-config >"$ndjson_output"
assert_file_contains "$ndjson_output" 'Primary finding contract: ndjson-v1' 'ndjson-v1 can be enabled explicitly for primary reviews'

cross_ndjson_config="$test_root/cross-ndjson.json"
cross_ndjson_output="$test_root/cross-ndjson-show-config.txt"
jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1"} | .prompts.cross_review = "Start with exactly this table"' "$config_file" >"$cross_ndjson_config"
"$repo_root/bin/review-pr" --config "$cross_ndjson_config" --show-config >"$cross_ndjson_output"
assert_file_contains "$cross_ndjson_output" 'Cross-review prompt: config (Markdown instructions are not sent under ndjson-v1)' \
    'show-config states that Markdown-oriented cross-review prompt instructions are ignored under the structured contract'
assert_file_contains "$cross_ndjson_output" 'Cross-review finding contract: ndjson-v1' 'ndjson-v1 can be enabled explicitly for cross-review'

final_ndjson_config="$test_root/final-ndjson.json"
final_ndjson_output="$test_root/final-ndjson-show-config.txt"
jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1", final: "ndjson-v1"} |
    .reporting.comparison_sections = {cross_review: "none", final: "standalone"}' "$config_file" >"$final_ndjson_config"
"$repo_root/bin/review-pr" --config "$final_ndjson_config" --show-config >"$final_ndjson_output"
assert_file_contains "$final_ndjson_output" 'Final finding contract: ndjson-v1' 'ndjson-v1 can be enabled explicitly for final synthesis'

invalid_final_dependency="$test_root/invalid-final-dependency.json"
jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "markdown", final: "ndjson-v1"}' "$config_file" >"$invalid_final_dependency"
if "$repo_root/bin/review-pr" --config "$invalid_final_dependency" --show-config >/dev/null 2>&1; then
    fail 'structured final synthesis without structured cross-review must fail'
fi
pass 'structured final synthesis requires structured primary and cross-review findings'

invalid_final_comparison="$test_root/invalid-final-comparison.json"
jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1", final: "ndjson-v1"} |
    .reporting.comparison_sections = {cross_review: "none", final: "inline"}' "$config_file" >"$invalid_final_comparison"
if "$repo_root/bin/review-pr" --config "$invalid_final_comparison" --show-config >/dev/null 2>&1; then
    fail 'structured final synthesis with inline comparison must fail'
fi
pass 'structured final synthesis rejects incompatible inline comparison output'

invalid_cross_dependency="$test_root/invalid-cross-dependency.json"
jq '.reporting.finding_contract = {primary: "markdown", cross_review: "ndjson-v1"}' "$config_file" >"$invalid_cross_dependency"
if "$repo_root/bin/review-pr" --config "$invalid_cross_dependency" --show-config >/dev/null 2>&1; then
    fail 'structured cross-review without structured primary findings must fail'
fi
pass 'structured cross-review requires structured primary findings'

invalid_cross_comparison="$test_root/invalid-cross-comparison.json"
jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1"} | .reporting.comparison_sections.cross_review = "inline"' "$config_file" >"$invalid_cross_comparison"
if "$repo_root/bin/review-pr" --config "$invalid_cross_comparison" --show-config >/dev/null 2>&1; then
    fail 'structured cross-review with inline comparison must fail'
fi
pass 'structured cross-review rejects incompatible inline comparison output'

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

dispute_config="$test_root/dispute.json"
dispute_output="$test_root/dispute-show-config.txt"
jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1", final: "ndjson-v1"} |
    .reporting.comparison_sections = {cross_review: "none", final: "none"} |
    .reporting.dispute_resolution = true' "$config_file" >"$dispute_config"
"$repo_root/bin/review-pr" --config "$dispute_config" --show-config >"$dispute_output"
assert_file_contains "$dispute_output" 'Dispute resolution: enabled' \
    'dispute resolution can be enabled on top of a structured final contract'
assert_file_contains "$show_output" 'Dispute resolution: disabled' \
    'dispute resolution is disabled by default'

dispute_without_final="$test_root/dispute-without-final.json"
jq '.reporting.dispute_resolution = true' "$config_file" >"$dispute_without_final"
if "$repo_root/bin/review-pr" --config "$dispute_without_final" --show-config >/dev/null 2>&1; then
    fail 'dispute resolution must require a structured final contract'
fi
pass 'dispute resolution is rejected without final=ndjson-v1'

dispute_wrong_type="$test_root/dispute-wrong-type.json"
jq '.reporting.dispute_resolution = "yes"' "$config_file" >"$dispute_wrong_type"
if "$repo_root/bin/review-pr" --config "$dispute_wrong_type" --show-config >/dev/null 2>&1; then
    fail 'non-boolean dispute_resolution must fail validation'
fi
pass 'non-boolean dispute_resolution is rejected'

measure_config="$test_root/measure.json"
measure_output="$test_root/measure-show-config.txt"
jq '.reporting.execute_measurements = true' "$dispute_config" >"$measure_config"
"$repo_root/bin/review-pr" --config "$measure_config" --show-config >"$measure_output"
assert_file_contains "$measure_output" 'Measurement execution: enabled' \
    'measurement execution can be enabled on top of dispute resolution'
assert_file_contains "$dispute_output" 'Measurement execution: disabled' \
    'measurement execution is disabled by default'
measure_without_disputes="$test_root/measure-without-disputes.json"
jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1", final: "ndjson-v1"} |
    .reporting.comparison_sections = {cross_review: "none", final: "none"} |
    .reporting.execute_measurements = true' "$config_file" >"$measure_without_disputes"
if "$repo_root/bin/review-pr" --config "$measure_without_disputes" --show-config >/dev/null 2>&1; then
    fail 'measurement execution must require dispute resolution'
fi
pass 'measurement execution is rejected without dispute_resolution'

# The findings export is published beside the final report for a fixing agent.
# It only makes sense for a structured final synthesis, and it can be turned off.
assert_file_contains "$show_output" 'Findings export: confirmed' \
    'the findings export defaults to the confirmed set'
export_config="$test_root/findings-export.json"
export_output="$test_root/findings-export-show-config.txt"
jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1", final: "ndjson-v1"} |
    .reporting.comparison_sections = {cross_review: "none", final: "none"} |
    .reporting.findings_export = "all"' "$config_file" >"$export_config"
"$repo_root/bin/review-pr" --config "$export_config" --show-config >"$export_output"
assert_file_contains "$export_output" 'Findings export: all' \
    'the exported scope is reported by --show-config'

export_off="$test_root/findings-export-off.json"
jq '.reporting.findings_export = "off"' "$config_file" >"$export_off"
"$repo_root/bin/review-pr" --config "$export_off" --show-config >"$test_root/findings-export-off.txt"
assert_file_contains "$test_root/findings-export-off.txt" 'Findings export: off' \
    'the findings export can be turned off'

export_invalid="$test_root/findings-export-invalid.json"
jq '.reporting.findings_export = "everything"' "$config_file" >"$export_invalid"
assert_false 'an unknown findings export scope is rejected' \
    "$repo_root/bin/review-pr" --config "$export_invalid" --show-config

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
