#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
set -euo pipefail
test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"
export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE
suite_root=$(portable_mktemp_dir review-pr-skill-prompt)
trap 'rm -rf -- "$suite_root"' EXIT

# A configured skill is review methodology, and skills written for this project
# carry a Markdown report template of their own. Under a structured contract that
# template competes with the record format the orchestrator requires, and the
# weakest runners follow the wrong one: on PR 29024 a reviewer emitted records in
# the final phase's shape with no source_refs at all.
AGENT_SKILL_FILE="$suite_root/SKILL.md"
printf '## Report\nProduce exactly these sections, in this order, all of them.\n' >"$AGENT_SKILL_FILE"
prompt="$suite_root/prompt.txt"
: >"$prompt"
append_configured_skill_to_prompt "$prompt"

assert_file_contains "$prompt" 'Produce exactly these sections' \
    'the configured skill itself is embedded'
assert_file_contains "$prompt" 'take precedence for persistence, for safety, and for the output format' \
    'the precedence the wrapper claims covers the output format, not only safety'
assert_file_contains "$prompt" 'classification vocabulary come from this prompt alone' \
    'the verdict words are claimed too, since the skills carry a vocabulary of their own'
assert_file_contains "$prompt" 'they apply to running the skill directly, not here' \
    'a report layout in the skill is scoped to direct use rather than forbidden outright'
printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
