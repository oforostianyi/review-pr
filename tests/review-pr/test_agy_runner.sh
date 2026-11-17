#!/usr/bin/env bash
# shellcheck disable=SC2034 # Tests assign the sourced orchestrator's globals.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

runner="$repo_root/runners/review-pr-agy"
suite_root=$(portable_mktemp_dir review-pr-agy-runner)
stand_in_pid=""
cleanup_suite() {
    [[ -z "$stand_in_pid" ]] || kill "$stand_in_pid" 2>/dev/null || true
    chmod -R u+w -- "$suite_root" 2>/dev/null || true
    rm -rf -- "$suite_root"
}
trap 'cleanup_suite' EXIT
fake_bin="$suite_root/bin"
state="$suite_root/state"
runner_tmp="$suite_root/tmp"
mkdir -p -- "$fake_bin" "$state" "$runner_tmp"
real_git=$(command -v git)
real_sleep=$(command -v sleep)
# TMPDIR is given through a symbolic link, as macOS gives /var for /private/var.
ln -s tmp "$suite_root/tmp-link"

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

# A stand-in for `agy`: it records what it sees from its working directory --
# the workspace the runner gave it -- and prints an event stream chosen by
# FAKE_AGY_MODE: success, denied (an empty response after a denied command),
# failed (a non-zero exit), or slow (success after a pause). A comma-separated
# list gives one mode per turn of a conversation, the last one repeating; each
# turn's arguments, message and directory are kept as args.N, prompt.N and
# cwd.N. FAKE_AGY_CONVERSATION puts a conversation id on the init event.
cat >"$fake_bin/agy" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$FAKE_AGY_STATE/agy_pid"
turn=$(( $(cat "$FAKE_AGY_STATE/turns" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$turn" >"$FAKE_AGY_STATE/turns"
printf '%s\n' "$*" >"$FAKE_AGY_STATE/args.$turn"
cat >"$FAKE_AGY_STATE/prompt.$turn"
[[ "$turn" != 1 ]] || cp -- "$FAKE_AGY_STATE/prompt.1" "$FAKE_AGY_STATE/prompt"
pwd -P >"$FAKE_AGY_STATE/cwd.$turn"
pwd -P >"$FAKE_AGY_STATE/cwd"
IFS=, read -r -a modes <<<"${FAKE_AGY_MODE:-success}"
if (( turn <= ${#modes[@]} )); then mode=${modes[turn - 1]}; else mode=${modes[${#modes[@]} - 1]}; fi
ls -ld . | cut -c1-10 >"$FAKE_AGY_STATE/mode"
ls -l file.txt 2>/dev/null | cut -c1-10 >"$FAKE_AGY_STATE/file_mode"
if [[ -d .git ]]; then echo directory; elif [[ -e .git ]]; then echo file; else echo none; fi >"$FAKE_AGY_STATE/git_kind"
git rev-parse HEAD >"$FAKE_AGY_STATE/head" 2>&1 || true
if [[ -n "${REVIEW_PR_BASE_SHA:-}" ]] && git diff --stat "${REVIEW_PR_BASE_SHA}...HEAD" >/dev/null 2>&1; then
    echo yes
else
    echo no
fi >"$FAKE_AGY_STATE/three_dot"
if [[ -e .git/objects/info/alternates ]]; then echo yes; else echo no; fi >"$FAKE_AGY_STATE/alternates"
if [[ -n "${FAKE_AGY_CONVERSATION:-}" ]]; then
    jq -cn --arg id "$FAKE_AGY_CONVERSATION" '{event: "init", conversation_id: $id}'
else
    printf '%s\n' '{"event":"init"}'
fi
case "$mode" in
    success|slow)
        [[ "$mode" != slow ]] || sleep 2
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"review text","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}'
        ;;
    two-results)
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"draft","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}'
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"review text","usage":{"total_tokens":40,"input_tokens":25,"output_tokens":15}}}'
        ;;
    success-resumed)
        # AGY 1.4.2 counts usage over the whole conversation, turns included.
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"recovered review","num_turns":2,"usage":{"total_tokens":350,"input_tokens":230,"output_tokens":120}}}'
        ;;
    denied)
        printf '{"event":"step_update","step_update":{"conversation_id":"c1","state":"ERROR","tool_info":{"tool_name":"run_command","parameters":{"CommandLine":"go test ./server\\u001b[2J"},"error":{"message":"permission check failed: command (turn %s)"}}}}\n' "$turn"
        printf '{"event":"result","result":{"status":"SUCCESS","response":"","num_turns":%s,"usage":{"total_tokens":%s,"input_tokens":%s,"output_tokens":%s}}}\n' \
            "$turn" "$((300 * turn))" "$((200 * turn))" "$((100 * turn))"
        ;;
    denied-1.4)
        printf '%s\n' '{"event":"step_update","step_update":{"step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"git log --oneline -1"},"output":"abc\\r\\n"}}}'
        printf '%s\n' '{"event":"step_update","step_update":{"step_index":4,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"go version"}}}}'
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10},"denied_actions":[{"action":"command","display_name":"RunCommand"}]}}'
        ;;
    denied-file)
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10},"denied_actions":[{"action":"read_file","display_name":"ReadFile"}]}}'
        ;;
    empty)
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"","usage":{"total_tokens":3,"input_tokens":2,"output_tokens":1}}}'
        ;;
    failed)
        exit 3
        ;;
    hang-after-success|hang-after-error)
        if [[ "$mode" == hang-after-success ]]; then
            printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"late review","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}'
        else
            printf '%s\n' '{"event":"result","result":{"status":"ERROR","response":"partial","error":"The stream was interrupted.\u001b[2J Please continue.","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}'
        fi
        # AGY 1.4 may keep running after its result and ignores TERM and INT;
        # a child of it, such as its sandbox helper, must not outlive it.
        trap '' TERM INT
        sleep 60 &
        printf '%s\n' "$!" >"$FAKE_AGY_STATE/child"
        exec sleep 30
        ;;
    torn)
        # Killed while it writes the next event: the last line is cut short.
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"whole review","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}'
        printf '%s' '{"event":"step_update","step_upd'
        trap '' TERM INT
        exec sleep 30
        ;;
    stubborn)
        # Works on, ignoring TERM and INT, with a child of its own.
        trap '' TERM INT
        sleep 60 &
        printf '%s\n' "$!" >"$FAKE_AGY_STATE/child"
        exec sleep 60
        ;;
    result-then-step)
        # An event after the result.
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"review text","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}'
        printf '%s\n' '{"event":"step_update","step_update":{"state":"DONE"}}'
        ;;
    nested-then-result)
        # A step whose parameters mention a result event, then the result
        # written in two parts, with a pause inside the line.
        # The pauses straddle the runner's checks, five seconds apart: one
        # sees only the step, the next the result line half written.
        printf '%s\n' '{"event":"step_update","step_update":{"tool_info":{"parameters":{"Query":{"event":"result"}}}}}'
        sleep 6
        printf '%s' '{"event":"result","result":{"status":"SUCCESS","response":"whole'
        sleep 6
        printf '%s\n' ' review","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}'
        trap '' TERM INT
        exec sleep 30
        ;;
    success-then-exit)
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"review text","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}'
        exit 3
        ;;
    signals)
        # Which of TTIN and TTOU the runner left ignored (Linux only).
        if [[ -r /proc/$$/status ]]; then
            mask=$(awk '/^SigIgn:/ {print $2}' "/proc/$$/status")
            if (( (16#$mask & 16#300000) == 16#300000 )); then echo ignored; else echo caught; fi
        else
            echo unknown
        fi >"$FAKE_AGY_STATE/tty_signals"
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"review text","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}'
        ;;
    undeletable)
        # Leaves something in its workspace that cannot be removed.
        mkdir locked
        : >locked/file
        chmod 500 locked
        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"review text","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}'
        ;;
esac
FAKE
chmod 700 "$fake_bin/agy"

# A git whose clone hangs and ignores TERM, when FAKE_GIT_SLOW_CLONE is set;
# and a sleep that counts how often it is started.
mkdir -p -- "$suite_root/shims"
cat >"$suite_root/shims/git" <<FAKE
#!/usr/bin/env bash
if [[ -n "\${FAKE_GIT_SLOW_CLONE:-}" && "\$1" == clone ]]; then
    printf '%s\\n' "\$\$" >"\$FAKE_AGY_STATE/git_pid"
    trap '' TERM INT
    exec "$real_sleep" 30
fi
exec "$real_git" "\$@"
FAKE
cat >"$suite_root/shims/sleep" <<FAKE
#!/usr/bin/env bash
printf '%s\\n' "\$1" >>"\$FAKE_AGY_STATE/sleeps"
exec "$real_sleep" "\$@"
FAKE
chmod 700 "$suite_root/shims/git" "$suite_root/shims/sleep"

# The review checkout: a clone of an origin whose PR head is checked out
# detached and whose base is known only by its commit, as the orchestrator
# leaves it after fetching both through FETCH_HEAD.
origin="$suite_root/origin"
git init -q -b main "$origin"
for content in one two three; do
    printf '%s\n' "$content" >"$origin/file.txt"
    git -C "$origin" add file.txt
    git -C "$origin" commit -q -m "$content"
done
mkdir -p "$origin/sub"
printf 'nested\n' >"$origin/sub/nested.txt"
printf 'dots\n' >"$origin/..config"
git -C "$origin" add sub/nested.txt ..config
git -C "$origin" commit -q -m nested
git -C "$origin" switch -q -c pr
printf 'pr\n' >"$origin/pr.txt"
git -C "$origin" add pr.txt
git -C "$origin" commit -q -m pr
git -C "$origin" switch -q main
printf 'base\n' >"$origin/base.txt"
git -C "$origin" add base.txt
git -C "$origin" commit -q -m base

make_checkout() {
    local target=$1
    shift

    git clone -q --no-checkout "$@" "file://$origin" "$target"
    git -C "$target" fetch -q --no-tags "$@" origin pr
    git -C "$target" switch -q --detach FETCH_HEAD
    git -C "$target" fetch -q --no-tags "$@" origin main
    git -C "$target" rev-parse FETCH_HEAD
    git -C "$target" update-ref -d refs/remotes/origin/main
    git -C "$target" update-ref -d refs/remotes/origin/pr 2>/dev/null || true
    git -C "$target" branch -q -D main 2>/dev/null || true
}

checkout="$suite_root/checkout"
base_sha=$(make_checkout "$checkout")
head_sha=$(git -C "$checkout" rev-parse HEAD)

run_runner() {
    local directory=$1
    shift

    (
        cd "$directory"
        umask 022
        env PATH="$fake_bin:$PATH" TMPDIR="$suite_root/tmp-link/" FAKE_AGY_STATE="$state" \
            REVIEW_PR_BASE_SHA="$base_sha" REVIEW_PR_USAGE_JSON="$state/usage.json" \
            REVIEW_PR_USAGE_FILE="$state/usage.txt" "$@" "$runner" \
            <<<'Review this pull request.' >"$state/stdout" 2>"$state/stderr"
    )
}

reset_state() {
    rm -f -- "$state"/*
}

leftover_workspaces() {
    find "$runner_tmp" -maxdepth 1 -name 'review-pr-agy*' -print
}

# A runner stopped by a signal removes its workspace in the background.
wait_for_no_leftovers() {
    local _

    for _ in $(seq 50); do
        [[ -n "$(leftover_workspaces)" ]] || return 0
        sleep 0.1
    done
}

process_is_gone() {
    ! kill -0 "$1" 2>/dev/null
}

# A successful review.
reset_state
run_status=0
run_runner "$checkout" || run_status=$?
assert_eq 0 "$run_status" 'a successful AGY review exits 0'
assert_eq 'review text' "$(cat "$state/stdout")" 'and prints the response'
workspace=$(cat "$state/cwd")
case "$workspace" in
    "$(cd -P "$runner_tmp" && pwd -P)"/review-pr-agy.??????/repo) workspace_named=true ;;
    *) workspace_named=false ;;
esac
assert_eq true "$workspace_named" 'AGY runs in the repo copy of a review-pr-agy directory under TMPDIR'
assert_eq directory "$(cat "$state/git_kind")" 'whose .git is a directory, not a link outside it'
assert_eq "$head_sha" "$(cat "$state/head")" 'at the checked-out PR head'
assert_eq yes "$(cat "$state/three_dot")" 'where the base...head diff works'
assert_eq drwx------ "$(cat "$state/mode")" 'and that only its owner can read'
assert_eq -rw------- "$(cat "$state/file_mode")" 'with private files whatever the umask'
assert_file_contains "$state/prompt" "Workspace: ${workspace}" 'the prompt names the workspace AGY runs in'
assert_false 'with no doubled slash' grep -q 'Workspace: .*//' "$state/prompt"
assert_false 'and no unresolved link' grep -q 'Workspace: .*tmp-link' "$state/prompt"
assert_eq 1 "$(git -C "$checkout" worktree list | wc -l | tr -d ' ')" 'no worktree is registered in the review checkout'
assert_eq '' "$(leftover_workspaces)" 'the workspace is removed afterwards, files starting with two dots included'
assert_eq 10 "$(jq -r '.output_tokens' "$state/usage.json")" 'the usage is normalized'

# A shallow review checkout copies only what its refs reach; the base must
# still be there.
shallow="$suite_root/shallow"
base_sha=$(make_checkout "$shallow" --depth 2)
reset_state
run_status=0
run_runner "$shallow" || run_status=$?
assert_eq 0 "$run_status" 'a shallow review checkout works'
assert_eq yes "$(cat "$state/three_dot")" 'and its workspace has the base for the base...head diff'
assert_eq '' "$(leftover_workspaces)" 'and is removed afterwards'
base_sha=$(git -C "$checkout" rev-parse FETCH_HEAD)

# A checkout that borrows objects from another repository: the workspace
# must not depend on a path outside it.
borrowing="$suite_root/borrowing"
git clone -q --no-checkout --reference "$origin" "file://$origin" "$borrowing"
git -C "$borrowing" switch -q --detach "$head_sha"
reset_state
run_status=0
run_runner "$borrowing" || run_status=$?
assert_eq 0 "$run_status" 'a checkout with alternates works'
assert_eq no "$(cat "$state/alternates")" 'and its workspace keeps no alternates'

# A stream with more than one result gives one usage summary, the last one's.
reset_state
run_runner "$checkout" FAKE_AGY_MODE=two-results
assert_eq 1 "$(jq -s 'length' "$state/usage.json")" 'a stream with two results gives one usage summary'
assert_eq 15 "$(jq -r '.output_tokens' "$state/usage.json")" 'from its last result'

# The runner may be started in a subdirectory of the checkout.
reset_state
run_status=0
run_runner "$checkout/sub" || run_status=$?
assert_eq 0 "$run_status" 'a runner started in a subdirectory works'
assert_eq "$head_sha" "$(cat "$state/head")" 'on the whole checkout'

# An empty response after a denied command continues the same conversation.
reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=denied,success-resumed REVIEW_PR_MODEL=fake-model REVIEW_PR_EFFORT=high || run_status=$?
assert_eq 0 "$run_status" 'an empty response after a denied command is continued, not failed'
assert_eq 'recovered review' "$(cat "$state/stdout")" 'and the follow-up turn gives the review'
assert_eq 2 "$(cat "$state/turns")" 'in one follow-up turn'
assert_eq '--conversation c1 --input-format stream-json --output-format stream-json --sandbox --model fake-model --effort high' \
    "$(cat "$state/args.2")" 'which resumes the conversation with the same flags'
assert_eq "$(cat "$state/cwd.1")" "$(cat "$state/cwd.2")" 'in the same workspace'
assert_eq user "$(jq -r '.event' "$state/prompt.2")" 'with one user message'
assert_false 'that does not quote the denied command' grep -q 'go test' "$state/prompt.2"
assert_file_contains "$state/prompt.2" 'was denied' 'and says a command was denied'
assert_file_contains "$state/stderr" 'review-pr-agy: AGY denied a command that no allow rule covers: go test ./server' \
    'the log says why the conversation goes on'
assert_file_contains "$state/stderr" 'continuing the conversation (follow-up 1 of 2)' 'and how many follow-ups are left'
assert_false 'with no failure line' grep -q 'review-pr-failure' "$state/stderr"
assert_eq 350 "$(jq -r '.reported_total_tokens' "$state/usage.json")" 'the usage is the conversation total that AGY reports cumulatively'
assert_eq 120 "$(jq -r '.output_tokens' "$state/usage.json")" 'output tokens included'
assert_eq 350 "$(cat "$state/usage.txt")" 'and the usage file gives the same total'
assert_eq '' "$(leftover_workspaces)" 'the workspace and every turn stream are removed'

# AGY 1.4 names the conversation on its init event and lists the denial in the
# result. A result without a turn count is a turn of its own; its usage is added.
reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=denied-1.4,success FAKE_AGY_CONVERSATION=conv-14 || run_status=$?
assert_eq 0 "$run_status" 'an AGY 1.4 denial is continued too'
assert_eq 'review text' "$(cat "$state/stdout")" 'and gives the review'
assert_file_contains "$state/args.2" '--conversation conv-14' 'in the conversation that the init event names'
assert_eq 60 "$(jq -r '.reported_total_tokens' "$state/usage.json")" 'turns that report usage of their own are added up'

# A command denied in every turn: two follow-ups at most, then the failure.
reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=denied || run_status=$?
assert_eq 1 "$run_status" 'a command denied in every turn fails'
assert_eq 3 "$(cat "$state/turns")" 'after two follow-ups'
assert_file_contains "$state/stderr" 'review-pr-failure: AGY denied a command that no allow rule covers: go test ./server' \
    'and names the denied command on a failure line'
assert_false 'without its control characters' grep -q $'\033' "$state/stderr"
for denied_turn in 1 2 3; do
    assert_file_contains "$state/stderr" "permission check failed: command (turn ${denied_turn})" \
        "the event stream of turn ${denied_turn} is in the log"
done
assert_file_contains "$state/stderr" 'review-pr-agy: event stream of turn 3 of 3' 'each under a heading'
assert_eq 300 "$(jq -r '.output_tokens' "$state/usage.json")" 'the tokens all turns spent are still reported'
assert_eq '' "$(leftover_workspaces)" 'and the workspace is removed'

# A follow-up turn that outlives its result is stopped like the first one.
reset_state
run_status=0
started_at=$EPOCHSECONDS
run_runner "$checkout" FAKE_AGY_MODE=denied,hang-after-success REVIEW_PR_AGY_RESULT_GRACE_SECONDS=1 || run_status=$?
assert_eq 0 "$run_status" 'a follow-up that hangs after its result still gives a review'
assert_eq 'late review' "$(cat "$state/stdout")" 'with the response of that result'
assert_true 'and is stopped after the grace period' test "$((EPOCHSECONDS - started_at))" -lt 20

reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=denied-1.4 || run_status=$?
assert_eq 1 "$run_status" 'an empty response with a denial in the result fails without a conversation id'
assert_eq 1 "$(cat "$state/turns")" 'as there is no conversation to continue'
assert_file_contains "$state/stderr" 'review-pr-failure: AGY denied a command that no allow rule covers: go version' \
    'and names the last command of the turn, as AGY 1.4 leaves it out of the denial'

reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=denied-1.4,success FAKE_AGY_CONVERSATION='--dangerously-skip-permissions' || run_status=$?
assert_eq 1 "$run_status" 'a conversation id that is not a plain identifier is not used'
assert_eq 1 "$(cat "$state/turns")" 'so the conversation is not continued'

# A follow-up that fails leaves every turn's stream in the error log.
reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=denied,failed || run_status=$?
assert_eq 1 "$run_status" 'a follow-up whose CLI fails fails the runner'
assert_file_contains "$state/stderr" 'event stream of turn 1 of 2' 'with the stream of the first turn in the log'
assert_file_contains "$state/stderr" 'event stream of turn 2 of 2' 'and of the follow-up'

# A runner stopped during a follow-up still reports what the finished turn
# spent, so a final synthesis that spent tokens can be retried.
reset_state
(
    cd "$checkout"
    exec env PATH="$fake_bin:$PATH" TMPDIR="$runner_tmp/" FAKE_AGY_STATE="$state" FAKE_AGY_MODE=denied,stubborn \
        REVIEW_PR_BASE_SHA="$base_sha" REVIEW_PR_USAGE_JSON="$state/usage.json" "$runner" <<<'Review.' >/dev/null 2>&1
) &
runner_pid=$!
for _ in $(seq 100); do
    [[ ! -s "$state/child" ]] || break
    sleep 0.1
done
kill -TERM "$runner_pid"
run_status=0
wait "$runner_pid" || run_status=$?
assert_eq 143 "$run_status" 'a runner stopped during a follow-up exits 143'
assert_eq 100 "$(jq -r '.output_tokens' "$state/usage.json" 2>/dev/null)" \
    'and has recorded the tokens of the turn before it'
wait_for_no_leftovers

reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=denied-file || run_status=$?
assert_file_contains "$state/stderr" 'review-pr-failure: AGY denied a tool call that no allow rule covers: ReadFile' \
    'a denied tool call other than a command is named by its action'

reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=empty || run_status=$?
assert_eq 1 "$run_status" 'an empty response with no denial in the stream fails'
assert_eq 1 "$(cat "$state/turns")" 'and is not continued'
assert_file_contains "$state/stderr" 'review-pr-failure: AGY returned an empty final response' \
    'with a failure line that says so'

# A failing CLI.
reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=failed || run_status=$?
assert_eq 1 "$run_status" 'a failing Antigravity CLI fails the runner'
assert_eq 1 "$(cat "$state/turns")" 'and is not continued'
assert_file_contains "$state/stderr" 'review-pr-failure: the Antigravity CLI exited with status 3' \
    'with a failure line that gives its exit status'
assert_eq '' "$(leftover_workspaces)" 'and the workspace is removed'

# AGY that keeps running after its result is stopped once the grace period
# has passed, and its result is used.
reset_state
run_status=0
started_at=$EPOCHSECONDS
run_runner "$checkout" FAKE_AGY_MODE=hang-after-success REVIEW_PR_AGY_RESULT_GRACE_SECONDS=1 || run_status=$?
assert_eq 0 "$run_status" 'AGY that hangs after a successful result still gives a review'
assert_eq 'late review' "$(cat "$state/stdout")" 'with the response of that result'
assert_true 'and is stopped long before it would exit on its own' test "$((EPOCHSECONDS - started_at))" -lt 20
assert_file_contains "$state/stderr" 'did not exit 1 s after its result' 'the log says why it was stopped'
assert_true 'and its child is stopped with it' process_is_gone "$(cat "$state/child")"
assert_eq '' "$(leftover_workspaces)" 'and the workspace is removed'

# A grace period with a leading zero is decimal, not an invalid octal number
# that leaves AGY running.
reset_state
run_status=0
started_at=$EPOCHSECONDS
run_runner "$checkout" FAKE_AGY_MODE=hang-after-success REVIEW_PR_AGY_RESULT_GRACE_SECONDS=08 || run_status=$?
assert_eq 0 "$run_status" 'a grace period of 08 works'
assert_file_contains "$state/stderr" 'did not exit 8 s after its result' 'and is read as 8 seconds'
assert_true 'so AGY is stopped before it would exit on its own' test "$((EPOCHSECONDS - started_at))" -lt 25

# A KILL can cut the last event short; the result before it still counts.
reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=torn REVIEW_PR_AGY_RESULT_GRACE_SECONDS=1 || run_status=$?
assert_eq 0 "$run_status" 'a torn last event does not lose the result'
assert_eq 'whole review' "$(cat "$state/stdout")" 'whose response is used'
assert_eq 10 "$(jq -r '.output_tokens' "$state/usage.json")" 'with its usage'
assert_file_contains "$state/stderr" 'dropped an incomplete or malformed line' 'and the log says a line was dropped'

# An event after the result does not lose the usage.
reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=result-then-step || run_status=$?
assert_eq 0 "$run_status" 'a stream with an event after its result works'
assert_eq 10 "$(jq -r '.output_tokens' "$state/usage.json")" 'and keeps its usage'

# The grace period starts at a complete result event: neither a step that
# mentions one nor a result line still being written starts it, even with no
# grace at all.
reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=nested-then-result REVIEW_PR_AGY_RESULT_GRACE_SECONDS=0 || run_status=$?
assert_eq 0 "$run_status" 'a result after a step that mentions one is waited for'
assert_eq 'whole review' "$(cat "$state/stdout")" 'and used whole'

# A non-zero exit after a successful result keeps the result.
reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=success-then-exit || run_status=$?
assert_eq 0 "$run_status" 'a successful result survives a non-zero exit'
assert_eq 'review text' "$(cat "$state/stdout")" 'whose response is used'
assert_file_contains "$state/stderr" 'exited with status 3 after a successful result' 'and the log says so'

# AGY runs in a background process group, so it must not be stopped for
# touching the terminal.
reset_state
run_runner "$checkout" FAKE_AGY_MODE=signals
case "$(cat "$state/tty_signals")" in
    ignored) pass 'AGY starts with TTIN and TTOU ignored' ;;
    unknown) pass 'no /proc here to read which signals AGY ignores' ;;
    *) fail 'AGY starts with TTIN and TTOU ignored' ;;
esac

# The wait for AGY starts one sleep every few seconds, not a sleep and a grep
# every second.
reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=hang-after-success REVIEW_PR_AGY_RESULT_GRACE_SECONDS=8 \
    PATH="$suite_root/shims:$fake_bin:$PATH" || run_status=$?
assert_eq 0 "$run_status" 'a run with counted sleeps works'
assert_true 'and starts at most three sleeps of its own in eight seconds' \
    test "$(awk '$1 <= 5' "$state/sleeps" | wc -l)" -le 3

# A workspace entry that cannot be removed does not change the exit status.
reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=undeletable || run_status=$?
assert_eq 0 "$run_status" 'a workspace that cannot be fully removed does not fail the review'
assert_eq 'review text' "$(cat "$state/stdout")" 'which prints its response'
chmod -R u+w "$runner_tmp"
rm -rf -- "$runner_tmp"/review-pr-agy.*

reset_state
run_status=0
run_runner "$checkout" FAKE_AGY_MODE=hang-after-error REVIEW_PR_AGY_RESULT_GRACE_SECONDS=1 || run_status=$?
assert_eq 1 "$run_status" 'an error result fails the runner'
assert_file_contains "$state/stderr" 'review-pr-failure: AGY ended with an error: The stream was interrupted.' \
    'with a failure line that quotes the error'
assert_false 'without its control characters' grep -q $'\033' "$state/stderr"
assert_eq 10 "$(jq -r '.output_tokens' "$state/usage.json")" 'and the tokens it spent are reported'

# A runner terminated while AGY works, AGY ignoring TERM, stops AGY and its
# child at once -- the orchestrator kills the runner 5 s after its TERM -- and
# removes its workspace.
reset_state
(
    cd "$checkout"
    exec env PATH="$fake_bin:$PATH" TMPDIR="$runner_tmp/" FAKE_AGY_STATE="$state" FAKE_AGY_MODE=stubborn \
        REVIEW_PR_BASE_SHA="$base_sha" "$runner" <<<'Review.' >/dev/null 2>&1
) &
runner_pid=$!
for _ in $(seq 50); do
    [[ ! -s "$state/child" ]] || break
    sleep 0.1
done
started_at=$EPOCHSECONDS
kill -TERM "$runner_pid"
run_status=0
wait "$runner_pid" || run_status=$?
assert_eq 143 "$run_status" 'a terminated runner exits 143'
assert_true 'within the 5 s the orchestrator allows' test "$((EPOCHSECONDS - started_at))" -lt 4
assert_true 'and AGY is stopped' process_is_gone "$(cat "$state/agy_pid")"
assert_true 'with its child' process_is_gone "$(cat "$state/child")"
wait_for_no_leftovers
assert_eq '' "$(leftover_workspaces)" 'and the workspace is removed'

# A runner terminated while it copies the checkout stops the copy at once.
reset_state
(
    cd "$checkout"
    exec env PATH="$suite_root/shims:$fake_bin:$PATH" TMPDIR="$runner_tmp/" FAKE_AGY_STATE="$state" \
        FAKE_GIT_SLOW_CLONE=1 REVIEW_PR_BASE_SHA="$base_sha" "$runner" <<<'Review.' >/dev/null 2>&1
) &
runner_pid=$!
for _ in $(seq 50); do
    [[ ! -s "$state/git_pid" ]] || break
    sleep 0.1
done
started_at=$EPOCHSECONDS
kill -TERM "$runner_pid"
run_status=0
wait "$runner_pid" || run_status=$?
assert_eq 143 "$run_status" 'a runner terminated during the copy exits 143'
assert_true 'within the 5 s the orchestrator allows' test "$((EPOCHSECONDS - started_at))" -lt 4
assert_true 'and the clone is stopped' process_is_gone "$(cat "$state/git_pid")"
wait_for_no_leftovers
assert_eq '' "$(leftover_workspaces)" 'and the workspace is removed'

# Directories left by a runner that was killed outright are swept once their
# owner is gone; the directory of a live runner stays however old it is.
( exit 0 ) &
dead_pid=$!
wait "$dead_pid"
mkdir -m 700 "$runner_tmp/review-pr-agy.DEADXX" "$runner_tmp/review-pr-agy.LIVEXX" \
    "$runner_tmp/review-pr-agy.NEWXXX" "$runner_tmp/review-pr-agy.OLDXXX" "$runner_tmp/review-pr-agy.REUSED"
printf '%s\n' "$dead_pid" >"$runner_tmp/review-pr-agy.DEADXX/owner"
printf '%s %s\n' "$$" "$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$$")" >"$runner_tmp/review-pr-agy.LIVEXX/owner"
printf '%s %s\n' "$$" 'Thu Jan  1 00:00:00 1970' >"$runner_tmp/review-pr-agy.REUSED/owner"
# A live runner whose reported start time moved, as a clock step makes it on
# Linux: its command line still names the runner.
# A long path puts the runner's name past column 80, where a narrow COLUMNS
# would cut the command line.
stand_in_name="/opt/$(printf 'deep-directory/%.0s' $(seq 8))review-pr-agy-stand-in"
bash -c 'exec -a "$1" sleep 60' _ "$stand_in_name" &
stand_in_pid=$!
mkdir -m 700 "$runner_tmp/review-pr-agy.MOVEDX"
printf '%s %s\n' "$stand_in_pid" 'Thu Jan  1 00:00:00 1970' >"$runner_tmp/review-pr-agy.MOVEDX/owner"
touch -t 202001010000 "$runner_tmp/review-pr-agy.LIVEXX" "$runner_tmp/review-pr-agy.OLDXXX"
reset_state
# A runner in another time zone reads the owner's start time alike.
run_runner "$checkout" TZ=Pacific/Kiritimati COLUMNS=80
assert_false 'the directory of a runner that is gone is swept' test -e "$runner_tmp/review-pr-agy.DEADXX"
assert_true 'that of a live runner stays, however old, read from another time zone' \
    test -d "$runner_tmp/review-pr-agy.LIVEXX"
assert_true 'one with no owner yet may be just starting and stays' test -d "$runner_tmp/review-pr-agy.NEWXXX"
assert_false 'unless it is an hour old' test -e "$runner_tmp/review-pr-agy.OLDXXX"
assert_false 'and a PID now held by another program started later does not keep a directory' \
    test -e "$runner_tmp/review-pr-agy.REUSED"
assert_true 'but a runner whose start time moved with the clock keeps its own' \
    test -d "$runner_tmp/review-pr-agy.MOVEDX"
kill "$stand_in_pid" 2>/dev/null || true
wait "$stand_in_pid" 2>/dev/null || true
stand_in_pid=""
rm -rf -- "$runner_tmp/review-pr-agy.MOVEDX"
rm -rf -- "$runner_tmp/review-pr-agy.LIVEXX" "$runner_tmp/review-pr-agy.NEWXXX"

# A live owner whose start time cannot be read keeps its directory.
mkdir -p -- "$suite_root/no-ps"
printf '#!/usr/bin/env bash\nexit 1\n' >"$suite_root/no-ps/ps"
chmod 700 "$suite_root/no-ps/ps"
mkdir -m 700 "$runner_tmp/review-pr-agy.NOPSXX"
printf '%s %s\n' "$$" 'Thu Jan  1 00:00:00 1970' >"$runner_tmp/review-pr-agy.NOPSXX/owner"
reset_state
run_runner "$checkout" PATH="$suite_root/no-ps:$fake_bin:$PATH"
assert_true 'a live owner whose start time cannot be read keeps its directory' \
    test -d "$runner_tmp/review-pr-agy.NOPSXX"
rm -rf -- "$runner_tmp/review-pr-agy.NOPSXX"

# An artifact-only run makes no workspace.
reset_state
run_status=0
run_runner "$suite_root" REVIEW_PR_ARTIFACT_ONLY=true || run_status=$?
assert_eq 0 "$run_status" 'an artifact-only run works outside a repository'
assert_eq "$(cd -P "$suite_root" && pwd -P)" "$(cat "$state/cwd")" 'in its own directory'
assert_eq '' "$(leftover_workspaces)" 'with no workspace'

# The orchestrator shows a runner's failure line with the exit status.
export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE
# The orchestrator sets an EXIT trap of its own; the suite's cleanup comes back.
trap 'cleanup_suite' EXIT
hint_log="$suite_root/hint.log"
printf '%s\n' 'noise' 'review-pr-failure: first' "review-pr-failure: last"$'\t'"cause" 'more noise' >"$hint_log"
assert_eq 'last cause' "$(runner_failure_hint "$hint_log")" 'the last failure line of a runner is its hint, control characters blanked'
printf 'review-pr-failure: %0300d\n' 0 >"$hint_log"
assert_eq 200 "$(runner_failure_hint "$hint_log" | wc -c | tr -d ' ')" 'and a long one is cut to 200 characters'
printf 'review-pr-failure: a\302\233b\342\200\256c\n' >"$hint_log"
assert_eq 'a b c' "$(runner_failure_hint "$hint_log")" 'C1 and bidirectional controls are blanked too'
assert_eq 'a b c' "$(LC_ALL=C runner_failure_hint "$hint_log")" 'whatever the locale'
printf 'review-pr-failure: %0300d\302\251\n' 0 >"$hint_log"
assert_eq 200 "$(runner_failure_hint "$hint_log" | jq -R -r length)" 'the limit counts characters, not bytes'
printf 'nothing to see\n' >"$hint_log"
assert_eq '' "$(runner_failure_hint "$hint_log")" 'a log without one gives no hint'
assert_eq '' "$(runner_failure_hint "$suite_root/missing.log")" 'nor does a missing log'

printf '1..%s\n' "$TEST_ASSERTIONS"
