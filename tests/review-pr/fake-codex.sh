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
printf '%s\n%s\n' "$record" "$complete" >"$output_file"
