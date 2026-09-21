#!/usr/bin/env bash
#
# Prints the CHANGELOG section for one version, for use as GitHub release notes.
#
# The section runs from its own `## [<version>]` heading to the next `## `
# heading. The Unreleased section and the file preamble are never part of it, and
# a version with no section is an error rather than an empty release page.
#
# Usage: release-notes.sh [--changelog <file>] <version>

set -euo pipefail

script_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
changelog="${script_dir}/../CHANGELOG.md"
version=""

while (( $# > 0 )); do
    case "$1" in
        --changelog)
            [[ $# -ge 2 ]] || { printf '%s\n' '--changelog requires a file' >&2; exit 2; }
            changelog=$2; shift 2 ;;
        --help|-h) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
        *)
            [[ -z "$version" ]] || { printf '%s\n' 'release-notes.sh takes a single version' >&2; exit 2; }
            version=$1; shift ;;
    esac
done

[[ -n "$version" ]] || { printf '%s\n' 'release-notes.sh requires a version' >&2; exit 2; }
[[ -f "$changelog" ]] || { printf 'No such changelog: %s\n' "$changelog" >&2; exit 2; }

notes=$(awk -v want="## [${version}]" '
    index($0, want) == 1 { collecting = 1; next }
    collecting && /^## / { exit }
    collecting { print }
' "$changelog")

# Trim the blank lines that the heading and the next section leave behind.
notes=$(printf '%s\n' "$notes" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')

[[ -n "$notes" ]] || { printf 'No changelog section for version %s in %s\n' "$version" "$changelog" >&2; exit 1; }
printf '%s\n' "$notes"
