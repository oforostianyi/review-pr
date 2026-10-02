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

suite_root=$(portable_mktemp_dir review-pr-codex-resume)
trap 'rm -rf -- "$suite_root"' EXIT
fake_bin="$suite_root/bin"
mkdir -p -- "$fake_bin" "$suite_root/repo" "$suite_root/work"

# A stand-in for `codex exec` and `codex exec resume`: it records its arguments
# and prompt, prints an event stream, and writes the last message. With
# FAKE_CODEX_RESUME=missing a resume fails before any turn, as Codex does for a
# session it cannot open.
cat >"$fake_bin/codex" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == exec ]] || exit 64
shift
printf '%s\n' "$*" >>"$FAKE_CODEX_CALLS"
output_file=''
resume=false
[[ "${1:-}" != resume ]] || resume=true
while (( $# > 0 )); do
    case "$1" in
        --output-last-message) output_file=$2; shift 2 ;;
        *) shift ;;
    esac
done
cat >>"$FAKE_CODEX_PROMPTS"
if [[ "$resume" == true && "${FAKE_CODEX_RESUME:-}" == missing ]]; then
    printf '%s\n' 'Error: no rollout found for thread id' >&2
    exit 1
fi
printf '%s\n' '{"type":"thread.started","thread_id":"01a0f446-0baf-7090-b7cf-d2f4bb5c6962"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"done"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2}}'
printf 'done\n' >"$output_file"
FAKE
chmod +x "$fake_bin/codex"
export FAKE_CODEX_CALLS="$suite_root/calls" FAKE_CODEX_PROMPTS="$suite_root/prompts"
PATH="$fake_bin:$PATH"

# Which failures a retry resumes.
events="$suite_root/events.jsonl"
thread='01a0f446-0baf-7090-b7cf-d2f4bb5c6962'
{
    printf '{"type":"thread.started","thread_id":"%s"}\n' "$thread"
    printf '%s\n' '{"type":"turn.started"}'
    printf '%s\n' '{"type":"error","message":"Selected model is at capacity. Please try a different model."}'
    printf '%s\n' '{"type":"turn.failed","error":{"message":"Selected model is at capacity. Please try a different model."}}'
} >"$events"
note_codex_resumable_session codex 'primary review' "$events"
assert_eq "$thread" "${CODEX_RESUME_SESSIONS[codex|primary review]:-}" \
    'a turn the provider failed leaves its session to resume (ListingSyncer 960)'
assert_eq 'Selected model is at capacity. Please try a different model.' \
    "${CODEX_RESUME_ERRORS[codex|primary review]:-}" 'with the error it failed on'
completed_events="$suite_root/completed.jsonl"
{
    printf '{"type":"thread.started","thread_id":"%s"}\n' "$thread"
    printf '%s\n' '{"type":"turn.started"}' '{"type":"turn.completed","usage":{}}'
} >"$completed_events"
note_codex_resumable_session codex 'primary review' "$completed_events"
assert_eq '' "${CODEX_RESUME_SESSIONS[codex|primary review]:-}" \
    'a turn that ran to its end is retried from the start, invalid stream and all'
printf '%s\n' '{"type":"thread.started","thread_id":"--sandbox"}' '{"type":"turn.failed","error":{"message":"x"}}' \
    >"$suite_root/odd.jsonl"
note_codex_resumable_session codex 'primary review' "$suite_root/odd.jsonl"
assert_eq '' "${CODEX_RESUME_SESSIONS[codex|primary review]:-}" \
    'and a thread id that could read as an option is never passed on'

# What the retry runs.
REVIEW_REPO="$suite_root/repo"
WORK_DIR="$suite_root/work"
REPORT_STEM=fixture
RETRY_MAX_ATTEMPTS=2
AGENT_MODELS[codex]=gpt-fixture
AGENT_EFFORTS[codex]=xhigh
prompt="$suite_root/prompt.txt"
printf 'Review the pull request.\n' >"$prompt"

run_codex_attempt() {
    local attempt=$1
    : >"$FAKE_CODEX_CALLS"; : >"$FAKE_CODEX_PROMPTS"
    start_agent codex 'primary review' "$prompt" "$suite_root/out" "$suite_root/log" \
        "$suite_root/usage" "$suite_root/usage.json" "$attempt" >/dev/null 2>&1
    wait "$STARTED_PID"
}

run_codex_attempt 1
assert_false 'a first attempt that a retry could follow records its session' \
    grep -q -- '--ephemeral' "$FAKE_CODEX_CALLS"
note_codex_resumable_session codex 'primary review' "$events"
run_codex_attempt 2
assert_true 'the retry after a provider error resumes that session, its read-only sandbox pinned' \
    grep -qx -- "resume ${thread} -c sandbox_mode=\"read-only\" --json --model gpt-fixture -c model_reasoning_effort=\"xhigh\" --output-last-message ${suite_root}/out -" "$FAKE_CODEX_CALLS"
assert_true 'and asks it to finish rather than start over' grep -q 'Continue the same task from where you stopped' "$FAKE_CODEX_PROMPTS"
assert_false 'without sending the review prompt a second time' grep -q 'Review the pull request' "$FAKE_CODEX_PROMPTS"
assert_eq '' "${CODEX_RESUME_SESSIONS[codex|primary review]:-}" 'the session is resumed once'

note_codex_resumable_session codex 'primary review' "$events"
FAKE_CODEX_RESUME=missing run_codex_attempt 2
assert_eq 2 "$(grep -c '' "$FAKE_CODEX_CALLS")" 'a session Codex cannot open is followed by a fresh attempt'
assert_true 'which runs the review prompt in the read-only sandbox' \
    grep -q -- '^--sandbox read-only' <(sed -n 2p "$FAKE_CODEX_CALLS")
assert_true 'and says so in the log' grep -q "Codex could not resume session ${thread}" "$suite_root/log"

run_codex_attempt 2
assert_eq 1 "$(grep -c '' "$FAKE_CODEX_CALLS")" 'a retry after any other failure starts over'
assert_false 'with nothing to resume' grep -q '^resume ' "$FAKE_CODEX_CALLS"

RETRY_MAX_ATTEMPTS=1
run_codex_attempt 1
assert_true 'with no retry to follow, the session is not recorded' grep -q -- '--ephemeral' "$FAKE_CODEX_CALLS"

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
