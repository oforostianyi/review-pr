#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Tests assign the sourced orchestrator's globals.
# The Claude quota: one short `claude -p` call per model reports the plan's
# limits in a rate_limit_event line, which review-pr reads, caches for a minute
# and, when quota.claude asks for it, holds to a minimum.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

suite_root=$(portable_mktemp_dir review-pr-quota-claude)
trap 'rm -rf -- "$suite_root"' EXIT
export XDG_CACHE_HOME="$suite_root/cache"
fake_bin="$suite_root/bin"
mkdir -p -- "$fake_bin"
original_path=$PATH

# A stand-in for `claude -p`: it records its arguments, one call per line, and
# prints the stream recorded for the model it was asked for ("default" without
# --model). FAKE_CLAUDE_SLEEP makes it hang first, FAKE_CLAUDE_EXIT fail.
cat >"$fake_bin/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_CLAUDE_CALLS"
model=default
while (( $# > 0 )); do
    if [[ "$1" == --model ]]; then model=$2; shift; fi
    shift
done
[[ -z "${FAKE_CLAUDE_SLEEP:-}" ]] || sleep "$FAKE_CLAUDE_SLEEP"
[[ ! -f "$FAKE_CLAUDE_STREAMS/$model.ndjson" ]] || cat "$FAKE_CLAUDE_STREAMS/$model.ndjson"
exit "${FAKE_CLAUDE_EXIT:-0}"
FAKE
chmod +x "$fake_bin/claude"
export FAKE_CLAUDE_CALLS="$suite_root/calls"
export FAKE_CLAUDE_STREAMS="$suite_root/streams"
mkdir -p -- "$FAKE_CLAUDE_STREAMS"
PATH="$fake_bin:$original_path"

# Writes the stream a model answers with: an init line, the given
# rate_limit_event's rate_limit_info (or none when empty), and a result line.
stream() {
    local model=$1 info=$2
    {
        printf '%s\n' '{"type":"system","subtype":"init","model":"x"}'
        [[ -z "$info" ]] || printf '{"type":"rate_limit_event","rate_limit_info":%s}\n' "$info"
        printf '%s\n' '{"type":"result","subtype":"success","result":"ok"}'
    } >"$FAKE_CLAUDE_STREAMS/$model.ndjson"
}

fresh() {
    : >"$FAKE_CLAUDE_CALLS"
    rm -rf -- "$XDG_CACHE_HOME/review-pr"
}

calls() { grep -c . "$FAKE_CLAUDE_CALLS" || :; }
windows() { jq -r '[.windows[] | "\(.name):\(.remaining_percent)"] | join("|")'; }

# Made-up figures in the shape Claude Code 2.1 prints.
fable_info='{"status":"allowed","rateLimitType":"seven_day","utilization":0.75,"overageEnabled":true,"isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.64,"resetsAt":1795006800,"status":"allowed"},"seven_day":{"utilization":0.75,"resetsAt":1795356000,"status":"allowed_warning","surpassedThreshold":0.75},"seven_day_overage_included":{"utilization":0.74,"resetsAt":1795356000,"status":"allowed"}}}'
plain_info='{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.02,"resetsAt":1795006800,"status":"allowed"},"seven_day":{"utilization":0.8,"resetsAt":1795356000,"status":"allowed"}}}'

fresh
stream mock-fable "$fable_info"
stream mock-haiku "$plain_info"
quota=$(read_claude_quota mock-fable)
assert_eq '5h:36|weekly:25|fable:26' "$(windows <<<"$quota")" \
    'the five-hour, weekly and Fable windows are read as what is left'
assert_eq 'mock-fable|true' "$(jq -r '"\(.model)|\(.available)"' <<<"$quota")" 'with the model the reading is for'
assert_eq '2026-11-18T13:00:00Z' "$(jq -r '.windows[0].reset_at' <<<"$quota")" 'and each reset as an instant'
assert_eq 'true|false' "$(jq -r '"\(.overage.enabled)|\(.overage.in_use)"' <<<"$quota")" \
    'whether extra usage is on and in use is kept'
call=$(head -n 1 "$FAKE_CLAUDE_CALLS")
for argument in '--model mock-fable' '--tools' '--setting-sources' '--strict-mcp-config' '--output-format stream-json' \
    '--no-session-persistence' '--max-turns 1'; do
    assert_true "the probe passes ${argument}" grep -q -- "$argument" <<<"$call"
done
assert_false 'and never --bare, which reads no plan login' grep -q -- '--bare' <<<"$call"
read_claude_quota mock-fable >/dev/null
assert_eq 1 "$(calls)" 'a second reading within a minute comes from the cache'
assert_eq '5h:98|weekly:20' "$(read_claude_quota mock-haiku | windows)" \
    'a model without a weekly limit of its own reports only the two plan windows'
assert_eq 2 "$(calls)" 'and the cache is kept per model'

fresh
stream mock-x '{"unifiedWindows":{"five_hour":{"utilization":0.3,"resetsAt":1795006800,"status":"allowed"},"seven_day":{"utilization":0.98,"resetsAt":1795356000,"status":"rejected"},"seven_day_opus":{"utilization":1.2,"resetsAt":1795356000,"status":"allowed"},"seven_day_sonnet":{"utilization":0.104,"resetsAt":1795356000,"status":"allowed"},"seven_day_future":{"utilization":0.5,"resetsAt":1795356000,"status":"allowed"}}}'
assert_eq '5h:70|weekly:0|opus:0|sonnet:90|seven_day_future:50' "$(read_claude_quota mock-x | windows)" \
    'a rejected window and one used past its limit have nothing left, and an unknown window keeps its name'

fresh
stream default "$plain_info"
assert_eq '5h:98|weekly:20' "$(read_claude_quota '' | windows)" 'an agent without a model is read with the CLI default'
assert_false 'and the probe then names no model' grep -q -- '--model' "$FAKE_CLAUDE_CALLS"
assert_file_exists "$XDG_CACHE_HOME/review-pr/quota-claude-default.json" 'cached as the default model'
fresh
stream 'vendor:model 1' "$plain_info"
read_claude_quota 'vendor:model 1' >/dev/null
assert_file_exists "$XDG_CACHE_HOME/review-pr/quota-claude-vendor_model_1.json" \
    'a model id is made safe for a file name'

fresh
stream mock-none ''
status=0; quota=$(read_claude_quota mock-none) || status=$?
assert_eq '1|false' "${status}|$(jq -r '.available' <<<"$quota")" 'a stream without a rate_limit_event is unavailable'
assert_true 'and says what was missing' grep -q 'rate_limit_event' <<<"$(jq -r '.error' <<<"$quota")"
assert_file_not_exists "$XDG_CACHE_HOME/review-pr/quota-claude-mock-none.json" 'an unavailable reading is not cached'

fresh
stream mock-fable "$fable_info"
# With a window spent and extra usage off, Claude Code refuses the call and
# exits non-zero, but it has reported the limits first: that refusal is the
# reading that matters most, not an unreadable one.
rejected_info='{"unifiedWindows":{"five_hour":{"utilization":1,"resetsAt":1795006800,"status":"rejected"},"seven_day":{"utilization":0.5,"resetsAt":1795356000,"status":"allowed"}}}'
stream mock-spent "$rejected_info"
status=0; quota=$(FAKE_CLAUDE_EXIT=1 read_claude_quota mock-spent) || status=$?
assert_eq '0|5h:0|weekly:50' "${status}|$(windows <<<"$quota")" \
    'a call refused for a spent window still reports the limits it printed'
fresh
stream mock-none ''
status=0; FAKE_CLAUDE_EXIT=1 read_claude_quota mock-none >/dev/null || status=$?
assert_eq 1 "$status" 'a failing claude call without a rate_limit_event is unavailable'

fresh
stream mock-odd '{"status":"allowed"}'
status=0; quota=$(read_claude_quota mock-odd) || status=$?
assert_eq '2|false' "${status}|$(jq -r '.available' <<<"$quota")" 'an event without unifiedWindows has a shape review-pr does not know'

fresh
stream mock-fable "$fable_info"
started=$EPOCHSECONDS
status=0; FAKE_CLAUDE_SLEEP=5 REVIEW_PR_QUOTA_TIMEOUT_SECONDS=1 read_claude_quota mock-fable >/dev/null || status=$?
assert_eq 1 "$status" 'a probe that hangs is unavailable'
assert_true 'and is given up after the quota timeout' test "$((EPOCHSECONDS - started))" -le 3

fresh
status=0; PATH=/usr/bin:/bin read_claude_quota mock-fable >/dev/null || status=$?
assert_eq 1 "$status" 'without Claude Code installed the quota is unavailable'

# The policy. Off until quota.claude asks for it; then the models of the
# built-in Claude agents a step would start are read, one probe per model, and
# a window below its minimum refuses the run, sets the agent aside for a phase,
# or fails a synthesis step -- the same four points as Codex.
declare -A AGENT_TYPES=([claude-a]=claude [claude-b]=claude [claude-h]=claude [claude-r]=claude [codex]=codex)
declare -A AGENT_MODELS=([claude-a]=mock-fable [claude-b]=mock-fable [claude-h]=mock-haiku [claude-r]=mock-fable [codex]=mock-codex)
declare -A AGENT_RUNNERS=([claude-r]=/opt/runner)
declare -A AGENT_COMMANDS=()
REVIEW_AGENTS=(claude-a codex)
FINAL_SYNTHESIZER=codex
FALLBACK_SYNTHESIZER=""
FINALIZATION_MODEL=""
FALLBACK_MODEL=""
QUOTA_CODEX_MINIMUM=""
short_info='{"unifiedWindows":{"five_hour":{"utilization":0.9,"resetsAt":1795006800,"status":"allowed"},"seven_day":{"utilization":0.5,"resetsAt":1795356000,"status":"allowed"},"seven_day_overage_included":{"utilization":0.5,"resetsAt":1795356000,"status":"allowed"}}}'
fable_short_info='{"unifiedWindows":{"five_hour":{"utilization":0.2,"resetsAt":1795006800,"status":"allowed"},"seven_day":{"utilization":0.5,"resetsAt":1795356000,"status":"allowed"},"seven_day_overage_included":{"utilization":0.99,"resetsAt":1795356000,"status":"allowed"}}}'
roomy_info='{"unifiedWindows":{"five_hour":{"utilization":0.2,"resetsAt":1795006800,"status":"allowed"},"seven_day":{"utilization":0.5,"resetsAt":1795356000,"status":"allowed"}}}'

fresh
stream mock-fable "$short_info"
QUOTA_CLAUDE_MINIMUM=""
assert_true 'with no Claude minimum configured the run is not checked' check_claude_quota_before_run all
claude_agents_short_of_quota cross-review claude-a codex 2>/dev/null
assert_eq '' "${CLAUDE_QUOTA_SKIPPED_AGENTS[*]}" 'and nothing is set aside for a phase'
assert_eq 0 "$(calls)" 'and Claude Code is not even asked'

QUOTA_CLAUDE_MINIMUM='{"5h":15}'
set +e
refusal=$( (check_claude_quota_before_run all) 2>&1 )
refusal_status=$?
set -e
assert_eq 1 "$refusal_status" 'a run that would start Claude with 10% left of its 5h window is refused'
assert_true 'and the refusal names the model, the window, what is left and the minimum' \
    grep -q 'mock-fable: 5h has 10% left, below its 15% minimum, until 2026-11-18T13:00:00Z' <<<"$refusal"
assert_true 'a --rerun-final whose synthesizers are not Claude is not checked' check_claude_quota_before_run synthesizers

fresh
stream mock-fable "$short_info"
FINAL_SYNTHESIZER=claude-h
stream mock-haiku "$roomy_info"
set +e
refusal=$( (check_claude_quota_before_run synthesizers) 2>&1 )
refusal_status=$?
set -e
assert_eq 0 "$refusal_status" 'a --rerun-final checks only the synthesizers'
assert_false 'and does not read the reviewers models' grep -q -- '--model mock-fable' "$FAKE_CLAUDE_CALLS"
FALLBACK_SYNTHESIZER=claude-a
set +e
refusal=$( (check_claude_quota_before_run synthesizers) 2>&1 )
refusal_status=$?
set -e
assert_eq 1 "$refusal_status" 'the fallback synthesizer is checked with them'
FALLBACK_MODEL=mock-haiku
assert_true 'on the fallback model when one is configured' check_claude_quota_before_run synthesizers
FALLBACK_SYNTHESIZER=""
FALLBACK_MODEL=""
FINAL_SYNTHESIZER=codex

fresh
stream mock-opus "$roomy_info"
AGENT_MODELS[claude-a]=mock-opus
QUOTA_CLAUDE_MINIMUM='{"fable":3}'
assert_true 'a Fable minimum does not refuse a run with no Fable model, whose probe reports no Fable window' \
    check_claude_quota_before_run all
AGENT_MODELS[claude-a]=mock-fable

fresh
stream mock-fable "$short_info"
stream mock-haiku "$roomy_info"
QUOTA_CLAUDE_MINIMUM=15
skip_log=$(claude_agents_short_of_quota cross-review claude-a claude-b claude-h codex 2>&1)
assert_eq 2 "$(calls)" 'the agents of a phase are read once per model'
claude_agents_short_of_quota cross-review claude-a claude-b claude-h codex 2>/dev/null
assert_eq 'claude-a claude-b' "${CLAUDE_QUOTA_SKIPPED_AGENTS[*]}" \
    'Claude reviewers on a model short of quota are set aside, and one on a model with enough left is not'
assert_true 'and the log says which window and that they are not started' \
    grep -q 'before the cross-review (mock-fable: 5h has 10% left.*); not starting claude-a claude-b for it' <<<"$skip_log"

fresh
stream mock-fable "$short_info"
claude_agents_short_of_quota cross-review claude-r codex 2>/dev/null
assert_eq '' "${CLAUDE_QUOTA_SKIPPED_AGENTS[*]}" 'an agent with its own runner is never set aside'
assert_eq 0 "$(calls)" 'and its account is never probed'
REVIEW_AGENTS=(claude-r codex)
assert_true 'nor does it refuse a run' check_claude_quota_before_run all
REVIEW_AGENTS=(claude-a codex)

fresh
stream mock-fable "$fable_short_info"
QUOTA_CLAUDE_MINIMUM='{"5h":15,"weekly":3,"fable":3}'
claude_agents_short_of_quota primary claude-a 2>/dev/null
assert_eq 'claude-a' "${CLAUDE_QUOTA_SKIPPED_AGENTS[*]}" 'a model short of its own weekly window is set aside'
assert_true 'naming that window' grep -q 'fable has 1% left, below its 3% minimum' <<<"$CLAUDE_QUOTA_SHORTFALL"

# An agent without a model runs on whatever default its settings pick, while
# the probe, which loads no settings, reads the CLI's own default: a minimum for
# a model's own weekly window may then never be checked, and the log says so.
fresh
stream default "$roomy_info"
AGENT_MODELS[claude-a]=""
QUOTA_CLAUDE_MINIMUM='{"5h":15,"fable":3}'
warning=$(check_claude_quota_before_run all 2>&1)
assert_true 'a model-window minimum with a Claude agent without a model is pointed out' \
    grep -q 'no model is configured.*fable.*may not be checked' <<<"$warning"
QUOTA_CLAUDE_MINIMUM='{"5h":15}'
warning=$(check_claude_quota_before_run all 2>&1)
assert_false 'but not when only plan windows have a minimum' grep -q 'no model is configured' <<<"$warning"
AGENT_MODELS[claude-a]=mock-fable

fresh
stream mock-fable ''
QUOTA_CLAUDE_MINIMUM=15
warning=$(check_claude_quota_before_run all 2>&1) && unknown_status=0 || unknown_status=$?
assert_eq 0 "$unknown_status" 'an unreadable Claude quota is not an exhausted one: the run goes on'
assert_true 'and the log says the check could not be made' grep -q 'Claude quota for mock-fable could not be read' <<<"$warning"
claude_agents_short_of_quota cross-review claude-a 2>/dev/null
assert_eq '' "${CLAUDE_QUOTA_SKIPPED_AGENTS[*]}" 'and no reviewer is set aside for it'

fresh
stream mock-fable "$short_info"
FINAL_SYNTHESIZER=claude-a
final_status=0; run_final_synthesis "$suite_root/final-error.log" 2>/dev/null || final_status=$?
assert_eq 1 "$final_status" 'a Claude synthesizer short of quota does not start the final'
assert_true 'and the failure reason names the window and its minimum' \
    grep -q '^Claude quota below its minimum before the final synthesis: mock-fable: 5h has 10% left, below its 15% minimum' <<<"$FINAL_FAILURE_REASON"
comparison_status=0; run_comparison_synthesis "$suite_root/comparison-error.log" 2>/dev/null || comparison_status=$?
assert_eq 1 "$comparison_status" 'nor the standalone comparison'
assert_true 'whose failure reason says the same' \
    grep -q '^Claude quota below its minimum before the standalone comparison: mock-fable: 5h' <<<"$COMPARISON_FAILURE_REASON"

fresh
stream mock-final "$short_info"
stream mock-fable "$roomy_info"
FINALIZATION_MODEL=mock-final
final_status=0; run_final_synthesis "$suite_root/final-error.log" 2>/dev/null || final_status=$?
assert_eq 1 "$final_status" 'the final is checked on the model it runs with, finalization.model'
assert_true 'which is the model probed' grep -q -- '--model mock-final' "$FAKE_CLAUDE_CALLS"
FINALIZATION_MODEL=""
FINAL_SYNTHESIZER=codex

# `review-pr quota claude` reads every model a run of the configuration would
# probe -- the synthesizer's, the fallback's and the enabled reviewers' -- once
# each. `review-pr quota` and `quota codex` stay Codex only, so nobody pays for a
# probe without asking for Claude.
checkout="$suite_root/checkout"
mkdir -p -- "$checkout"
config="$suite_root/config.json"
jq -n --arg checkout "$checkout" --arg reviews "$suite_root/reviews" '{
    agents: {
        "claude-a": {type: "claude", enabled: true, model: "mock-fable"},
        "claude-h": {type: "claude", enabled: true, model: "mock-haiku"},
        "claude-off": {type: "claude", enabled: false, model: "mock-off"}
    },
    reviewers: ["claude-a", "claude-h", "claude-off"],
    synthesizer: "claude-a",
    default_repository: "fixture",
    repositories: {fixture: {github: "Example/Repository", checkout: $checkout}},
    reviews_directory: $reviews,
    language: "EN"
}' >"$config"
quota_cli() { TZ=UTC "$repo_root/bin/review-pr" --config "$config" quota "$@"; }

fresh
stream mock-fable "$fable_info"
stream mock-haiku "$plain_info"
cli_status=0; table=$(quota_cli claude) || cli_status=$?
assert_eq 0 "$cli_status" 'review-pr quota claude exits 0 when every model was read'
assert_eq $'Claude mock-fable\n  5h             36% left   resets Wed 18 Nov 13:00\n  weekly         25% left   resets Sun 22 Nov 14:00\n  fable          26% left   resets Sun 22 Nov 14:00\nClaude mock-haiku\n  5h             98% left   resets Wed 18 Nov 13:00\n  weekly         20% left   resets Sun 22 Nov 14:00' \
    "$table" 'and prints each model the run would use with its windows, a disabled reviewer left out'
assert_eq 2 "$(calls)" 'one probe per model'
assert_eq 'mock-fable,mock-haiku' "$(quota_cli claude --json | jq -r 'map(.model) | join(",")')" \
    'review-pr quota claude --json prints the readings as one array'

fresh
stream mock-fable "$fable_info"
stream mock-haiku ''
cli_status=0; table=$(quota_cli claude) || cli_status=$?
assert_eq 1 "$cli_status" 'a model whose quota cannot be read makes it exit 1'
assert_true 'and its line says why' grep -q '^Claude mock-haiku: quota unavailable (' <<<"$table"
assert_true 'while the models that were read are still shown' grep -q '^Claude mock-fable$' <<<"$table"

fresh
quota_cli >/dev/null 2>&1 || :
quota_cli codex >/dev/null 2>&1 || :
assert_eq 0 "$(calls)" 'review-pr quota and quota codex never ask Claude Code'
assert_false 'a provider review-pr cannot read is refused' quota_cli gemini
assert_true 'with a message naming the two it can' grep -q 'codex or claude' <<<"$(quota_cli gemini 2>&1 || :)"

no_claude="$suite_root/no-claude.json"
jq '.agents = {"x": {type: "codex", enabled: true}, "y": {type: "codex", enabled: true}} | .reviewers = ["x", "y"] | .synthesizer = "x"' "$config" >"$no_claude"
fresh
cli_status=0; table=$(TZ=UTC "$repo_root/bin/review-pr" --config "$no_claude" quota claude) || cli_status=$?
assert_eq '0|No Claude agent to check.' "${cli_status}|${table}" 'a configuration without a Claude agent has nothing to check'
assert_eq 0 "$(calls)" 'and asks Claude Code nothing'

PATH=$original_path

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
