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

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
