#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Tests assign the sourced orchestrator's globals.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

suite_root=$(portable_mktemp_dir review-pr-skill-lookup)
trap 'rm -rf -- "$suite_root"' EXIT

CONFIG_DIRECTORY="$suite_root/config"
mkdir -p -- "$CONFIG_DIRECTORY/skills/pi/php-code-review"
printf 'canonical pi skill\n' >"$CONFIG_DIRECTORY/skills/pi/php-code-review/SKILL.md"

# A skill is resolved by agent key first and by adapter type second, so a second
# Pi inherits the skill of the adapter that runs it. The portable copy embedded in
# the prompt was found by key alone, so an agent with a new key silently ran
# without it -- the same skill name, but 22KB of it missing from the prompt.
AGENT_SKILLS=([pi]=php-code-review [pi-local]=php-code-review)
AGENT_TYPES=([pi-local]=pi)

agent_skill_instruction pi
assert_eq "$CONFIG_DIRECTORY/skills/pi/php-code-review/SKILL.md" "$AGENT_SKILL_FILE" \
    'an agent whose key matches the skill directory finds its portable copy'

agent_skill_instruction pi-local
assert_eq "$CONFIG_DIRECTORY/skills/pi/php-code-review/SKILL.md" "$AGENT_SKILL_FILE" \
    'an agent with its own key falls back to the copy filed under its adapter type'

mkdir -p -- "$CONFIG_DIRECTORY/skills/pi-local/php-code-review"
printf 'copy filed under the key itself\n' >"$CONFIG_DIRECTORY/skills/pi-local/php-code-review/SKILL.md"
agent_skill_instruction pi-local
assert_eq "$CONFIG_DIRECTORY/skills/pi-local/php-code-review/SKILL.md" "$AGENT_SKILL_FILE" \
    'a copy filed under the key itself still wins over the adapter one'

AGENT_TYPES=([orphan]=runner)
AGENT_SKILLS=([orphan]=php-code-review)
agent_skill_instruction orphan
assert_eq '' "$AGENT_SKILL_FILE" \
    'an adapter with no copy of its own embeds nothing rather than guessing'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
