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

suite_root=$(portable_mktemp_dir review-pr-dashboard-refresh)
trap 'rm -rf -- "$suite_root"' EXIT

# A frame is redrawn by moving the cursor up its own height, which assumes the
# previous frame is whole. Killing the refresher in the middle of one leaves the
# cursor inside the frame, and the redraw stop_dashboard does next lands above
# it -- the tail of the old frame then survives under whatever the run printed.
refresh_case="$suite_root/dashboard-refresh"
mkdir -p -- "$refresh_case"
refresh_frames="$refresh_case/frames.txt"
STATUS_REFRESH_INTERVAL_SECONDS=0.1
render_dashboard_snapshot() {
    printf 'FRAME-BEGIN\n' >>"$refresh_frames"
    sleep 0.6
    printf 'FRAME-END\n' >>"$refresh_frames"
}

: >"$refresh_frames"
# The loop now leaves through a normal exit, so an inherited EXIT trap would run
# the orchestrator's whole cleanup a second time, from a subshell.
refresh_exit_marker="$refresh_case/exit-trap.txt"
: >"$refresh_exit_marker"
refresh_saved_trap=$(trap -p EXIT)
trap 'printf "INHERITED-EXIT-TRAP-RAN\n" >>"$refresh_exit_marker"; rm -rf -- "$suite_root"' EXIT
dashboard_refresh_loop &
refresh_pid=$!
sleep 0.4                       # inside the frame, not inside the wait
kill "$refresh_pid" 2>/dev/null || true
wait "$refresh_pid" 2>/dev/null || true
assert_eq "$(grep -c FRAME-BEGIN "$refresh_frames")" "$(grep -c FRAME-END "$refresh_frames")" \
    'a refresher stopped mid-frame finishes the frame it was drawing'
assert_true 'and it had in fact started one' \
    grep -q FRAME-BEGIN "$refresh_frames"
assert_false 'the refresher does not run the inherited exit trap on its way out' \
    grep -q INHERITED-EXIT-TRAP-RAN "$refresh_exit_marker"
eval "$refresh_saved_trap"

# Asking instead of killing must not cost a whole refresh interval: an idle
# refresher is interrupted in its wait, not after it.
: >"$refresh_frames"
STATUS_REFRESH_INTERVAL_SECONDS=30
dashboard_refresh_loop &
refresh_pid=$!
sleep 0.2
refresh_stop_started=$(date +%s)
kill "$refresh_pid" 2>/dev/null || true
wait "$refresh_pid" 2>/dev/null || true
assert_true 'an idle refresher stops at once rather than finishing its wait' \
    test "$(( $(date +%s) - refresh_stop_started ))" -lt 5
assert_false 'and it draws no further frame on the way out' \
    grep -q FRAME-BEGIN "$refresh_frames"

# log() hands its lines to the renderer, but a warning from gh, git or jq went
# straight into the frame and every later redraw stranded a copy of its top line.
# While the table is up the run's stderr goes to the message file instead, and
# it is the terminal again once the table is down.
capture_case="$suite_root/stderr-capture"
mkdir -p -- "$capture_case"
DASHBOARD_MESSAGE_FILE="$capture_case/messages.txt"
: >"$DASHBOARD_MESSAGE_FILE"
exec {test_stderr}>&2
exec 2>"$capture_case/terminal.txt"
capture_dashboard_stderr
printf 'a warning written straight to stderr\n' >&2
sh -c 'printf "and one from a child process" >&2'
restore_dashboard_stderr
printf 'after the table\n' >&2
exec 2>&"$test_stderr" {test_stderr}>&-
assert_file_contains "$DASHBOARD_MESSAGE_FILE" 'a warning written straight to stderr' \
    'a line written to stderr while the table is up is held for the renderer'
assert_file_contains "$DASHBOARD_MESSAGE_FILE" 'and one from a child process' \
    'and so is one from a child process'
assert_false 'neither reaches the terminal under the frame' \
    grep -q 'warning written straight' "$capture_case/terminal.txt"
assert_file_contains "$capture_case/terminal.txt" 'after the table' \
    'and stderr is the terminal again once the table is down'
flushed="$capture_case/flushed.txt"
flush_dashboard_messages 2>"$flushed"
assert_eq 2 "$(wc -l <"$flushed" | tr -d ' ')" \
    'the renderer prints the held lines, closing one that had no newline'
# Emptying the file after printing it lost whatever a writer appended between
# the two; the renderer now reads on from where it stopped.
printf 'written after the first flush\n' >>"$DASHBOARD_MESSAGE_FILE"
flush_dashboard_messages 2>"$flushed"
assert_eq 'written after the first flush' "$(cat "$flushed")" \
    'a later flush prints only what came after the last one'
flush_dashboard_messages 2>"$flushed"
assert_false 'and prints nothing twice' test -s "$flushed"
flush_dashboard_messages true 2>"$flushed"
assert_false 'the last flush, when the table is down, empties the message file' test -s "$DASHBOARD_MESSAGE_FILE"

# A writer can append while a flush copies: the flush measures the file and a
# burst lands before the copy is done. The copy read to the file's end and let
# head cut it short, so tail went on writing into a pipe head had closed, and
# under pipefail the SIGPIPE ended the shell that was flushing. A stand-in for wc
# reports the size the file had before a mebibyte arrived.
burst_case="$suite_root/burst"
mkdir -p -- "$burst_case"
DASHBOARD_MESSAGE_FILE="$burst_case/messages.txt"
printf 'measured line\n' >"$DASHBOARD_MESSAGE_FILE"
head -c 1048576 /dev/zero | tr '\0' x >>"$DASHBOARD_MESSAGE_FILE"
set +e
(
    set -e
    wc() { printf '14\n'; }
    flush_dashboard_messages
) 2>"$burst_case/flushed.txt"
burst_status=$?
set -e
assert_eq 0 "$burst_status" 'a burst appended during a flush does not end the flushing shell'
assert_eq 'measured line' "$(cat "$burst_case/flushed.txt")" \
    'the flush prints exactly what it measured'
assert_eq 14 "$(cat "${DASHBOARD_MESSAGE_FILE}.offset")" \
    'and leaves the burst for the next flush'

# Both ways the table comes down print what the run said last while it was up:
# stop_dashboard at the end of a run, and cleanup on the way out of one that
# died, whose ERROR line went into the message file like every other.
render_dashboard_snapshot() { :; }
teardown_case="$suite_root/teardown"
mkdir -p -- "$teardown_case"
DASHBOARD_MESSAGE_FILE="$teardown_case/stop-messages.txt"
: >"$DASHBOARD_MESSAGE_FILE"
exec {test_stderr}>&2
exec 2>"$teardown_case/stop-terminal.txt"
sleep 30 &
DASHBOARD_PID=$!
DASHBOARD_ACTIVE=true
capture_dashboard_stderr
printf 'written while the table was up\n' >&2
stop_dashboard
printf 'written after the table\n' >&2
exec 2>&"$test_stderr" {test_stderr}>&-
assert_file_contains "$teardown_case/stop-terminal.txt" 'written while the table was up' \
    'stop_dashboard prints what the run wrote while the table was up'
assert_file_contains "$teardown_case/stop-terminal.txt" 'written after the table' \
    'and hands stderr back to the terminal'
assert_false 'and empties the message file' test -s "$DASHBOARD_MESSAGE_FILE"

cleanup_status=0
(
    RUN_HISTORY_FILE=""
    RUNNING_PIDS=()
    TEMP_FILES=()
    LOCK_ACQUIRED=false
    REPOSITORY_FACTS_PUBLISHING=false
    CHANGED_LINE_MAP_PUBLISHING=false
    DASHBOARD_MESSAGE_FILE="$teardown_case/die-messages.txt"
    : >"$DASHBOARD_MESSAGE_FILE"
    DASHBOARD_PID=""
    DASHBOARD_ACTIVE=true
    trap cleanup EXIT
    capture_dashboard_stderr
    die 'the run failed while the table was up'
) 2>"$teardown_case/die-terminal.txt" || cleanup_status=$?
assert_eq 1 "$cleanup_status" 'a run that dies with the table up keeps its exit status'
assert_file_contains "$teardown_case/die-terminal.txt" 'ERROR: the run failed while the table was up' \
    'and cleanup prints its ERROR line once the table is down'
assert_false 'and empties the message file' test -s "$teardown_case/die-messages.txt"

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
