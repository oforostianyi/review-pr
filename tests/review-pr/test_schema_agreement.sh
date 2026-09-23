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
schema_efforts() {
    jq -r --arg def "$1" '.["$defs"][$def].enum | sort | join(",")' "$schema"
}

assert_eq 'auto' "$(jq -r '.["$defs"].claudeEffort.enum | map(select(. == "auto")) | join(",")' "$schema")" \
    'the schema accepts auto as a Claude effort'
assert_eq 'auto' "$(jq -r '.["$defs"].codexEffort.enum | map(select(. == "auto")) | join(",")' "$schema")" \
    'the schema accepts auto as a Codex effort'
assert_eq 'auto' "$(jq -r '.["$defs"].piThinking.enum | map(select(. == "auto")) | join(",")' "$schema")" \
    'the schema accepts auto as a Pi thinking level'

assert_eq ',auto,high,low,max,medium,xhigh' "$(schema_efforts claudeEffort)" \
    'the Claude vocabulary is exactly what the orchestrator accepts'
assert_eq ',auto,high,low,max,medium,none,xhigh' "$(schema_efforts codexEffort)" \
    'the Codex vocabulary is exactly what the orchestrator accepts'
assert_eq ',auto,high,low,max,medium,minimal,off,xhigh' "$(schema_efforts piThinking)" \
    'the Pi vocabulary is exactly what the orchestrator accepts'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
