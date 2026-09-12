#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Tests assign the sourced orchestrator's globals and index its associative arrays.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

test_root=$(portable_mktemp_dir review-pr-changed-lines)
trap 'rm -rf -- "$test_root"' EXIT
repository="$test_root/repository"
WORK_DIR="$test_root/work"
newline_path=$'odd\nname.txt'
mkdir -p -- "$repository" "$WORK_DIR"

git init --quiet "$repository"
git -C "$repository" config user.name 'Review PR Tests'
git -C "$repository" config user.email 'review-pr-tests@example.test'
printf 'one\ntwo\nthree\nfour\nfive\nsix\n' >"$repository/modified file.txt"
printf 'remove me\n' >"$repository/deleted.txt"
printf 'keep one\ndelete two\nkeep three\n' >"$repository/deletion-only.txt"
for line_number in {1..20}; do
    printf 'rename line %02d\n' "$line_number" >>"$repository/rename-old.txt"
done
printf '\000base-binary\n' >"$repository/image.bin"
printf 'old newline path content\n' >"$repository/$newline_path"
git -C "$repository" add -A
git -C "$repository" commit --quiet -m base
BASE_SHA=$(git -C "$repository" rev-parse HEAD)

printf 'one\ntwo\nTHREE\nfour\nfive\nsix\nseven\n' >"$repository/modified file.txt"
rm -- "$repository/deleted.txt"
printf 'keep one\nkeep three\n' >"$repository/deletion-only.txt"
git -C "$repository" mv rename-old.txt rename-new.txt
awk 'NR == 7 { print "renamed and changed line 07"; next } { print }' \
    "$repository/rename-new.txt" >"$repository/rename-new.tmp"
mv -- "$repository/rename-new.tmp" "$repository/rename-new.txt"
printf '\000head-binary\n' >"$repository/image.bin"
printf 'new newline path content\n' >"$repository/$newline_path"
printf 'added one\nadded two\n' >"$repository/added.txt"
git -C "$repository" add -A
git -C "$repository" commit --quiet -m head
HEAD_SHA=$(git -C "$repository" rev-parse HEAD)

cd "$repository"
REPORT_STEM=fixture
GITHUB_REPOSITORY=example/repository
PR_NUMBER=123
REPOSITORY_FACTS_JSON_FILE=""
collect_changed_line_map

assert_file_exists "$CHANGED_LINE_MAP_FILE" 'changed-line collector publishes its JSON map'
assert_eq "$BASE_SHA" "$(jq -r '.base_sha' "$CHANGED_LINE_MAP_FILE")" \
    'changed-line map records the exact base commit'
assert_eq "$HEAD_SHA" "$(jq -r '.head_sha' "$CHANGED_LINE_MAP_FILE")" \
    'changed-line map records the exact head commit'
assert_eq '7' "$(jq -r '.files | length' "$CHANGED_LINE_MAP_FILE")" \
    'changed-line map retains every changed path'
assert_eq 'true' "$(jq -r '.files[] | select(.path == "modified file.txt") | any(.right_side_ranges[]; .start <= 3 and .["end"] >= 3)' "$CHANGED_LINE_MAP_FILE")" \
    'modified RIGHT-side line is anchorable'
assert_eq 'false' "$(jq -r '.files[] | select(.path == "modified file.txt") | any(.right_side_ranges[]; .start <= 2 and .["end"] >= 2)' "$CHANGED_LINE_MAP_FILE")" \
    'unchanged context line is excluded from the map'
assert_eq 'rename-old.txt' "$(jq -r '.files[] | select(.path == "rename-new.txt") | .old_path' "$CHANGED_LINE_MAP_FILE")" \
    'rename map keeps the old path but keys anchors by the RIGHT-side path'
assert_eq 'true' "$(jq -r '.files[] | select(.path == "rename-new.txt") | any(.right_side_ranges[]; .start <= 7 and .["end"] >= 7)' "$CHANGED_LINE_MAP_FILE")" \
    'content changed within a rename has a RIGHT-side anchor'
assert_eq '0' "$(jq -r '.files[] | select(.path == "deleted.txt") | .right_side_line_count' "$CHANGED_LINE_MAP_FILE")" \
    'deleted file has no fabricated RIGHT-side lines'
assert_eq '0' "$(jq -r '.files[] | select(.path == "deletion-only.txt") | .right_side_line_count' "$CHANGED_LINE_MAP_FILE")" \
    'deletion-only hunk has no RIGHT-side changed anchor'
assert_eq 'true' "$(jq -r '.files[] | select(.path == "image.bin") | .binary' "$CHANGED_LINE_MAP_FILE")" \
    'binary change is explicit'
assert_eq 'false' "$(jq -r '.files[] | select(.path == "image.bin") | .inline_anchorable' "$CHANGED_LINE_MAP_FILE")" \
    'binary file is not line-anchorable'
assert_eq '2' "$(jq -r '.files[] | select(.path == "added.txt") | .right_side_line_count' "$CHANGED_LINE_MAP_FILE")" \
    'added text file exposes all new RIGHT-side lines'
assert_eq '1' "$(jq -r --arg path "$newline_path" '.files[] | select(.path == $path) | .right_side_line_count' "$CHANGED_LINE_MAP_FILE")" \
    'NUL-delimited collection preserves a filename containing a newline'

if (REPORT_STEM=broken; BASE_SHA=0000000000000000000000000000000000000000; collect_changed_line_map) \
    >"$test_root/broken-output.log" 2>&1; then
    fail 'invalid diff commits must fail changed-line collection'
fi
pass 'changed-line collection failure is visible'
assert_file_not_exists "$WORK_DIR/broken-changed-lines.json" \
    'failed changed-line collection publishes no canonical map'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
