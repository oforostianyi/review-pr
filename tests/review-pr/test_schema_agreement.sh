#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Tests assign the sourced orchestrator's globals.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

schema="$repo_root/config/review-pr.schema.json"

# The published schema is what an editor validates against, and the orchestrator's
# own validator is what decides whether a run starts. When they disagree, a
# configuration is red in the editor and accepted by the tool, or the reverse. The
# effort vocabularies drifted apart exactly that way when `auto` was added.
# jq 1.6 reads `def` after a dollar sign as the keyword, so the name is `$name`.
schema_efforts() {
    jq -r --arg name "$1" '.["$defs"][$name].enum | sort | join(",")' "$schema"
}

assert_eq 'auto' "$(jq -r '.["$defs"].claudeEffort.enum | map(select(. == "auto")) | join(",")' "$schema")" \
    'the schema accepts auto as a Claude effort'
assert_eq 'auto' "$(jq -r '.["$defs"].codexEffort.enum | map(select(. == "auto")) | join(",")' "$schema")" \
    'the schema accepts auto as a Codex effort'
assert_eq 'auto' "$(jq -r '.["$defs"].piThinking.enum | map(select(. == "auto")) | join(",")' "$schema")" \
    'the schema accepts auto as a Pi thinking level'

assert_eq ',auto,high,low,max,medium,xhigh' "$(schema_efforts claudeEffort)" \
    'the Claude vocabulary is exactly what the orchestrator accepts'
assert_eq ',auto,high,low,max,medium,none,ultra,xhigh' "$(schema_efforts codexEffort)" \
    'the Codex vocabulary is exactly what the orchestrator accepts'
assert_eq ',auto,high,low,max,medium,minimal,off,xhigh' "$(schema_efforts piThinking)" \
    'the Pi vocabulary is exactly what the orchestrator accepts'

# The orchestrator refuses a quota.codex without its threshold, so the schema
# must not show `"quota": {"codex": {}}` as valid (self-review of 2e3acc4).
assert_eq 'minimum_remaining_percent' \
    "$(jq -r '.properties.quota.properties.codex.required // [] | join(",")' "$schema")" \
    'the schema requires the threshold the orchestrator requires under quota.codex'
# The threshold is a number or an object with a minimum per window; the schema
# must offer both, and an empty object is refused by both.
assert_eq 'number,object' \
    "$(jq -r '[.properties.quota.properties.codex.properties.minimum_remaining_percent.oneOf[].type] | sort | join(",")' "$schema")" \
    'the schema accepts a number or an object as the Codex minimum'
assert_eq '1' \
    "$(jq -r '.properties.quota.properties.codex.properties.minimum_remaining_percent.oneOf[] | select(.type == "object") | .minProperties' "$schema")" \
    'and an object with no window in it is invalid in the schema as well'
# quota.claude mirrors it, with Claude's own window names.
assert_eq 'minimum_remaining_percent' \
    "$(jq -r '.properties.quota.properties.claude.required // [] | join(",")' "$schema")" \
    'the schema requires the threshold the orchestrator requires under quota.claude'
assert_eq 'number,object' \
    "$(jq -r '[.properties.quota.properties.claude.properties.minimum_remaining_percent.oneOf[].type] | sort | join(",")' "$schema")" \
    'the schema accepts a number or an object as the Claude minimum'
assert_eq '1|^(5h|weekly|fable|opus|sonnet)$' \
    "$(jq -r '.properties.quota.properties.claude.properties.minimum_remaining_percent.oneOf[] | select(.type == "object") | "\(.minProperties)|\(.propertyNames.pattern)"' "$schema")" \
    'and names exactly the windows the orchestrator accepts'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
