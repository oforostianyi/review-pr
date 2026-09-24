#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Tests assign the sourced orchestrator's globals and read arrays it fills through namerefs.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

test_root=$(portable_mktemp_dir review-pr-quorum)
trap 'rm -rf -- "$test_root"' EXIT

WORK_DIR=$test_root
REPORT_STEM=quorum
MANIFEST_FILE="$test_root/manifest.json"
printf '%s\n' '{"agent_losses": []}' >"$MANIFEST_FILE"

REVIEW_AGENTS=(claude codex pi pi-local)
for agent in "${REVIEW_AGENTS[@]}"; do
    PRIMARY_OUTPUTS[$agent]="$test_root/${agent}.md"
    CROSS_OUTPUTS[$agent]="$test_root/cross-${agent}.md"
done
write_report() { printf 'report\n' >"$1"; }

# The floor is two because a finding is checked by everyone but its author: with
# C reviewers left, a survivor's own findings are seen by C - 1 others.
AGENT_QUORUM=2
assert_eq 2 "$(effective_quorum 4)" 'a quorum of two stays two while four reviewers are listed'
assert_eq 2 "$(effective_quorum 2)" 'and asks for both when only two are listed'
AGENT_QUORUM=5
assert_eq 3 "$(effective_quorum 3)" 'a quorum above the number listed means all of them'
AGENT_QUORUM=all
assert_eq 4 "$(effective_quorum 4)" 'all means every reviewer listed'
AGENT_QUORUM=2

# Survivors are read from the artifacts on disk, so a fresh run and a resumed one
# are judged the same way.
for agent in claude codex pi pi-local; do write_report "${PRIMARY_OUTPUTS[$agent]}"; done
for agent in claude codex pi; do write_report "${CROSS_OUTPUTS[$agent]}"; done
refresh_phase_survivors
assert_eq 'claude codex pi pi-local' "${PRIMARY_AGENTS[*]}" 'every reviewer with a primary report is a primary survivor'
assert_eq 'claude codex pi' "${CROSS_AGENTS[*]}" 'a reviewer whose cross-review is missing is not a cross survivor'

# The case that cost 29031 its final: four primary reviews and three
# cross-reviews finished, one reviewer failed twice.
PHASE_FAILURES=('pi-local (invalid cross-review ndjson-v1 output (schema); 2 attempts)')
assert_true 'three of four finished cross-reviews meet a quorum of two' \
    phase_may_continue_without_failures cross
assert_eq 'cross-review' "$(jq -r '.agent_losses[0].phase' "$MANIFEST_FILE")" \
    'the manifest names the phase the reviewer dropped out of'
assert_eq 'pi-local' "$(jq -r '.agent_losses[0].agent' "$MANIFEST_FILE")" \
    'and the reviewer'
assert_eq 'invalid cross-review ndjson-v1 output; 2 attempts' "$(jq -r '.agent_losses[0].reason' "$MANIFEST_FILE")" \
    'and says what kind of failure it was, briefly enough to read in a report'
assert_true 'while the full diagnostic is kept alongside it' \
    grep -q '(schema)' <<<"$(jq -r '.agent_losses[0].detail' "$MANIFEST_FILE")"
assert_true 'a reviewer the quorum set aside is known as dropped' \
    agent_was_dropped 'cross-review' pi-local
assert_false 'while one that finished is not' \
    agent_was_dropped 'cross-review' claude
assert_false 'and dropping out of one phase does not mark another' \
    agent_was_dropped 'primary review' pi-local

# Two survivors still mean every finding has somebody else to check it.
rm -f -- "${CROSS_OUTPUTS[pi]}"
PHASE_FAILURES=('pi (timeout; 2 attempts)' 'pi-local (schema; 2 attempts)')
assert_true 'two of four finished cross-reviews still meet a quorum of two' \
    phase_may_continue_without_failures cross

# One survivor would leave its own findings unchecked, so the run stops.
rm -f -- "${CROSS_OUTPUTS[codex]}"
PHASE_FAILURES=('codex (exit 1; 2 attempts)' 'pi (timeout; 2 attempts)' 'pi-local (schema; 2 attempts)')
printf '%s\n' '{"agent_losses": []}' >"$MANIFEST_FILE"
assert_false 'a single finished cross-review is below the quorum' \
    phase_may_continue_without_failures cross
assert_eq 0 "$(jq '.agent_losses | length' "$MANIFEST_FILE")" \
    'and a phase that stops records no reviewer as merely dropped'

# A quorum of all restores the old behaviour exactly: any failure stops the run.
AGENT_QUORUM=all
for agent in claude codex pi; do write_report "${CROSS_OUTPUTS[$agent]}"; done
PHASE_FAILURES=('pi-local (schema; 2 attempts)')
assert_false 'with a quorum of all, one failed reviewer still stops the run' \
    phase_may_continue_without_failures cross
AGENT_QUORUM=2

# A reviewer that failed its primary review takes no part in cross-review, and
# the ones that finished are judged against the reviewers that remained.
rm -f -- "${PRIMARY_OUTPUTS[pi-local]}" "${CROSS_OUTPUTS[pi-local]}"
PHASE_FAILURES=('pi-local (timeout; 2 attempts)')
printf '%s\n' '{"agent_losses": []}' >"$MANIFEST_FILE"
assert_true 'three of four primary reviews meet a quorum of two' \
    phase_may_continue_without_failures primary
assert_eq 'claude codex pi' "${PRIMARY_AGENTS[*]}" \
    'the reviewer that failed its primary review is out of the later phases'
assert_eq 'primary review' "$(jq -r '.agent_losses[0].phase' "$MANIFEST_FILE")" \
    'and the loss is recorded against the primary review'

# Consumers fall back to every listed reviewer until a run has looked at its
# own artifacts, which is how unit tests and contract tests call them.
PRIMARY_AGENTS=()
CROSS_AGENTS=()
survivor_agents primary fallback_sources
assert_eq 'claude codex pi pi-local' "${fallback_sources[*]}" \
    'with nothing computed yet, the sources are everyone listed'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
