#!/usr/bin/env bash

set -euo pipefail

[[ "${1:-}" == exec ]] || { printf '%s\n' 'fake Codex expected exec' >&2; exit 64; }
shift

output_file=''
skip_git_check=false
while (( $# > 0 )); do
    case "$1" in
        --skip-git-repo-check)
            skip_git_check=true
            shift
            ;;
        --output-last-message)
            (( $# >= 2 )) || exit 64
            output_file=$2
            shift 2
            ;;
        --cd | --model | -c)
            (( $# >= 2 )) || exit 64
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[[ "$skip_git_check" == true ]] || { printf '%s\n' 'missing --skip-git-repo-check' >&2; exit 65; }
[[ -n "$output_file" ]] || { printf '%s\n' 'missing --output-last-message' >&2; exit 65; }

prompt=$(cat)
record=$(awk '/^Return exactly two physical lines/{seen=1; next} seen && /^\{/{print; exit}' <<<"$prompt")
complete=$(awk '/^Line 2 must be this exact JSON object:/{getline; print; exit}' <<<"$prompt")
[[ -n "$record" && -n "$complete" ]] || { printf '%s\n' 'could not extract contract fixture' >&2; exit 65; }

# Like `codex exec --json`, print the event stream on stdout and write the last
# agent message to --output-last-message. With REVIEW_PR_FAKE_CODEX_SPLIT_MESSAGES
# the two lines arrive as two agent messages, so the last message alone is
# an incomplete stream.
emit_event() { printf '%s\n' "$1"; }
emit_event '{"type":"thread.started","thread_id":"fake-thread"}'
emit_event '{"type":"turn.started"}'
if [[ "${REVIEW_PR_FAKE_CODEX_SPLIT_MESSAGES:-false}" == true ]]; then
    jq -nc --arg text "$record" '{type: "item.completed", item: {id: "item_1", type: "agent_message", text: $text}}'
    jq -nc --arg text "$complete" '{type: "item.completed", item: {id: "item_2", type: "agent_message", text: $text}}'
    printf '%s\n' "$complete" >"$output_file"
else
    jq -nc --arg text "$(printf '%s\n%s' "$record" "$complete")" '{type: "item.completed", item: {id: "item_1", type: "agent_message", text: $text}}'
    printf '%s\n%s\n' "$record" "$complete" >"$output_file"
fi
emit_event '{"type":"turn.completed","usage":{"input_tokens":120,"cached_input_tokens":0,"output_tokens":40}}'
