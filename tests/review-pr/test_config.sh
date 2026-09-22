#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

test_root=$(portable_mktemp_dir review-pr-config)
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p -- "$test_root/repository" "$test_root/reviews"

# --show-config requires the CLI of every enabled built-in adapter. The runners are
# not installed everywhere the suite runs, so inert stand-ins answer for them; only
# Pi is asked about its flags.
mkdir -p -- "$test_root/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "--append-system-prompt <text>" "--thinking <level>"\n' >"$test_root/bin/pi"
for stub in claude codex; do
    printf '#!/bin/sh\nexit 0\n' >"$test_root/bin/$stub"
done
chmod 0755 "$test_root/bin/pi" "$test_root/bin/claude" "$test_root/bin/codex"
export PATH="$test_root/bin:$PATH"

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
"$repo_root/bin/review-pr" --config "$pi_thinking_config" --show-config >"$pi_thinking_output" 2>&1 \
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

# A rejected configuration has to say what is wrong with it. The validator is one
# long boolean, so without this the user is told only that the file is invalid and
# has to bisect a hundred conditions by hand.
config_error() {
    local candidate=$1
    "$repo_root/bin/review-pr" --config "$candidate" --show-config >/dev/null 2>"$test_root/config-error.txt" || true
    cat "$test_root/config-error.txt"
}

disabled_synthesizer="$test_root/disabled-synthesizer.json"
jq '.agents.beta.enabled = false | .agents.gamma = {"label": "Gamma", enabled: true, model: "m", effort: ""} |
    .reviewers = ["alpha", "beta", "gamma"] | .synthesizer = "beta"' "$config_file" >"$disabled_synthesizer"
assert_file_contains <(config_error "$disabled_synthesizer") 'is disabled' \
    'a disabled synthesizer is reported as disabled'
assert_file_contains <(config_error "$disabled_synthesizer") '"beta"' \
    'the error names the agent that cannot synthesize'

too_few_reviewers="$test_root/too-few-reviewers.json"
jq '.agents.beta.enabled = false' "$config_file" >"$too_few_reviewers"
assert_file_contains <(config_error "$too_few_reviewers") 'two enabled reviewers' \
    'a review that cannot be cross-checked says so'

unknown_key="$test_root/unknown-key.json"
jq '.reviewrs = ["alpha"]' "$config_file" >"$unknown_key"
assert_file_contains <(config_error "$unknown_key") 'reviewrs' \
    'a misspelled top-level key is quoted back'

bad_effort="$test_root/bad-effort.json"
jq '.agents.claude = {"label": "Claude", enabled: true, model: "claude-opus-5", effort: "extreme"} |
    .reviewers = ["claude", "alpha", "beta"]' "$config_file" >"$bad_effort"
assert_file_contains <(config_error "$bad_effort") 'extreme' \
    'an unsupported effort value is quoted back'

assert_file_contains <(config_error "$export_invalid") 'findings_export' \
    'an unknown export scope names the setting it belongs to'

# The agent key used to be the choice of runner, so one CLI could serve one agent
# and a second Pi with a different model was impossible. `type` names the adapter;
# the key stays a free label and keeps owning the artifacts.
two_pi="$test_root/two-pi.json"
jq '.agents = {
        "pi-local": {"label": "Pi local", enabled: true, type: "pi", model: "dirk-local", effort: "high", max_tool_calls: 300},
        "pi-cloud": {"label": "Pi cloud", enabled: true, type: "pi", model: "vendor/flash", effort: "low", max_tool_calls: 120},
        "opus": {"label": "Opus", enabled: true, type: "claude", model: "claude-opus-5", effort: "high"}
    } | .reviewers = ["pi-local", "pi-cloud", "opus"] | .synthesizer = "pi-cloud"
    | .profiles.fixture.skills = {"pi-local": "php-code-review"}' "$config_file" >"$two_pi"
assert_true 'two agents may share the pi adapter with different models' \
    "$repo_root/bin/review-pr" --config "$two_pi" --show-config
assert_file_contains <("$repo_root/bin/review-pr" --config "$two_pi" --show-config) 'pi-local pi-cloud opus' \
    'every agent of a shared type is active'

# The budget is a property of the Pi runner, not of the agent that happens to be
# called "pi", so every agent of that type may set one.
unknown_type="$test_root/unknown-type.json"
jq '.agents.alpha.type = "gemini"' "$config_file" >"$unknown_type"
assert_false 'an unknown adapter type is rejected' \
    "$repo_root/bin/review-pr" --config "$unknown_type" --show-config
assert_file_contains <(config_error "$unknown_type") 'gemini' \
    'the error quotes the adapter it does not know'

budget_on_typed_pi="$test_root/budget-typed.json"
jq '.agents.beta = {"label": "Beta", enabled: true, type: "pi", model: "m", effort: "", max_tool_calls: 50}' \
    "$config_file" >"$budget_on_typed_pi"
assert_true 'a tool-call budget belongs to the pi adapter, not to the key "pi"' \
    "$repo_root/bin/review-pr" --config "$budget_on_typed_pi" --show-config

budget_on_claude="$test_root/budget-claude.json"
jq '.agents.beta = {"label": "Beta", enabled: true, type: "claude", model: "m", effort: "", max_tool_calls: 50}' \
    "$config_file" >"$budget_on_claude"
assert_false 'a tool-call budget is still refused for an adapter that cannot enforce it' \
    "$repo_root/bin/review-pr" --config "$budget_on_claude" --show-config

typed_effort="$test_root/typed-effort.json"
jq '.agents.beta = {"label": "Beta", enabled: true, type: "codex", model: "m", effort: "none"}' \
    "$config_file" >"$typed_effort"
assert_true 'the effort vocabulary follows the adapter, not the key' \
    "$repo_root/bin/review-pr" --config "$typed_effort" --show-config
jq '.agents.beta = {"label": "Beta", enabled: true, type: "claude", model: "m", effort: "none"}' \
    "$config_file" >"$typed_effort"
assert_false 'an effort the adapter does not accept is still refused' \
    "$repo_root/bin/review-pr" --config "$typed_effort" --show-config

# A second agent of a known type should not silently lose its review skill just
# because the skills map does not mention its key. Look the key up first, so an
# explicit entry still wins, then fall back to the adapter.
skill_config="$test_root/skill-inheritance.json"
jq '.agents = {
        "pi-local": {"label": "Pi local", enabled: true, type: "pi", model: "m1", effort: ""},
        "pi-cloud": {"label": "Pi cloud", enabled: true, type: "pi", model: "m2", effort: ""}
    } | .reviewers = ["pi-local", "pi-cloud"] | .synthesizer = "pi-local"
    | .profiles.fixture.skills = {"pi": "php-code-review", "pi-cloud": "other-review"}' \
    "$config_file" >"$skill_config"
skill_output=$("$repo_root/bin/review-pr" --config "$skill_config" --show-config)
assert_file_contains <(printf '%s\n' "$skill_output") 'pi-local: skill=php-code-review' \
    'an agent without its own skill entry inherits the one configured for its type'
assert_file_contains <(printf '%s\n' "$skill_output") 'pi-cloud: skill=other-review' \
    'an explicit entry for the agent key still wins over the type'

# Timestamps used to be pinned to one maintainer's zone. The setting moves all of
# them together -- run identifiers, manifest times, log lines, the dashboard clock.
timezone_config="$test_root/timezone.json"
jq '.timezone = "America/New_York"' "$config_file" >"$timezone_config"
assert_file_contains <("$repo_root/bin/review-pr" --config "$timezone_config" --show-config) \
    'Timezone: America/New_York' 'the configured timezone is visible in diagnostics'
assert_file_contains <("$repo_root/bin/review-pr" --config "$config_file" --show-config) \
    'Timezone: system default' 'an unset timezone follows the machine'

# TZ never reports an unknown zone; it silently gives UTC, so a typo would rename
# every run without a word.
unknown_timezone="$test_root/unknown-timezone.json"
jq '.timezone = "Europe/Warsow"' "$config_file" >"$unknown_timezone"
assert_file_contains <(config_error "$unknown_timezone") 'Europe/Warsow' \
    'a misspelled timezone is quoted back instead of silently becoming UTC'
assert_file_contains <(config_error "$unknown_timezone") 'timezone' \
    'the error names the setting the typo is in'

traversing_timezone="$test_root/traversing-timezone.json"
jq '.timezone = "../../etc/passwd"' "$config_file" >"$traversing_timezone"
assert_file_contains <(config_error "$traversing_timezone") 'timezone' \
    'a timezone that is a path rather than a zone name is refused'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
