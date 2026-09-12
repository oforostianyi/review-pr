#!/usr/bin/env bash
# Builds the release archive into a temporary directory and audits its
# contents, permissions, and checksum, then installs from the extracted
# archive to prove one archive serves a clean installation.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

test_root=$(portable_mktemp_dir review-pr-package)
trap 'rm -rf -- "$test_root"' EXIT

package_version=$(sed -n '1p' "$repo_root/VERSION")
package_name="review-pr-${package_version}"
dist_dir="$test_root/dist with space"

REVIEW_PR_DIST_DIR="$dist_dir" bash "$repo_root/packaging/build-package.sh" >"$test_root/build.txt" 2>&1 \
    || fail "package build failed: $(cat "$test_root/build.txt")"
archive="$dist_dir/${package_name}.tar.gz"
checksum_file="$dist_dir/${package_name}.tar.gz.sha256"
assert_file_exists "$archive" 'the build writes the archive into the requested distribution directory'
assert_file_exists "$checksum_file" 'the build writes a SHA-256 checksum file beside the archive'
assert_false 'the build leaves nothing else in the distribution directory' \
    test -n "$(find "$dist_dir" -type f ! -name "${package_name}.tar.gz" ! -name "${package_name}.tar.gz.sha256" -print)"

if command -v sha256sum >/dev/null 2>&1; then
    assert_true 'the checksum file verifies with sha256sum' bash -c 'cd "$1" && sha256sum -c --quiet "$2"' _ "$dist_dir" "${package_name}.tar.gz.sha256"
else
    assert_true 'the checksum file verifies with shasum' bash -c 'cd "$1" && shasum -a 256 -c "$2" >/dev/null' _ "$dist_dir" "${package_name}.tar.gz.sha256"
fi
assert_eq "${package_name}.tar.gz" "$(awk '{print $NF}' "$checksum_file" | sed 's/^\*//')" \
    'the checksum names the archive by its bare file name so it verifies from any directory'

# Contents must match the documented manifest in both directions.
tar -tzf "$archive" >"$test_root/entries.txt"
grep -v '/$' "$test_root/entries.txt" | sed "s#^${package_name}/##" | sort >"$test_root/archive-files.txt"
grep -v '^#' "$repo_root/packaging/package-manifest.txt" | grep -v '^$' | sort >"$test_root/manifest-files.txt"
assert_true 'the archive contains exactly the documented files' \
    cmp -s "$test_root/manifest-files.txt" "$test_root/archive-files.txt"
assert_true 'every archive entry lives under the versioned root directory' \
    bash -c '! grep -v "^$1/" "$2"' _ "$package_name" "$test_root/entries.txt"
for forbidden in 'dist/' '\.git/' 'config\.json$' 'tests/' '\.claude/' '\.github/' '\.remember/' 'skills/' 'backups/'; do
    assert_false "the archive contains no ${forbidden} entries" grep -Eq "$forbidden" "$test_root/entries.txt"
done

# Modes: executables are 0755, data files 0644, and no entry is a symlink.
tar -tvzf "$archive" >"$test_root/verbose.txt"
mode_of() {
    awk -v name="${package_name}/$1" '$NF == name {print substr($1, 1, 10)}' "$test_root/verbose.txt"
}
for executable in bin/review-pr runners/review-pr-agy install.sh uninstall.sh review-pr-launcher; do
    assert_eq '-rwxr-xr-x' "$(mode_of "$executable")" "${executable} is packaged as executable"
done
for data_file in VERSION README.md CHANGELOG.md runners/review-pr-pi-guard.js config/review-pr.example.json \
    config/review-pr.schema.json config/review-pr-findings-v1.schema.json docs/review-pr.md docs/review-pr-finding-contract.md; do
    assert_eq '-rw-r--r--' "$(mode_of "$data_file")" "${data_file} is packaged read-only"
done
assert_false 'the archive contains no symlinks' grep -q '^l' "$test_root/verbose.txt"
assert_eq "$package_version" "$(tar -xzOf "$archive" "${package_name}/VERSION")" \
    'the packaged VERSION matches the repository VERSION'
assert_eq "$package_version" "$(tar -xzOf "$archive" "${package_name}/bin/review-pr" | sed -n 's/^readonly REVIEW_PR_VERSION="\([^"]*\)"$/\1/p')" \
    'the packaged implementation reports the package version'

# Installing from the extracted archive reproduces a clean installation.
extract_dir="$test_root/extract here"
mkdir -p -- "$extract_dir"
tar -xzf "$archive" -C "$extract_dir"
assert_true 'the archive extracts under its versioned directory' test -d "$extract_dir/$package_name"
fake_bin="$test_root/bin"
mkdir -p -- "$fake_bin"
ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
for hosted_command in claude codex; do
    printf '#!/bin/sh\nexit 0\n' >"$fake_bin/$hosted_command"
    chmod 0755 "$fake_bin/$hosted_command"
done
home_dir="$test_root/home"
checkout="$test_root/checkout"
mkdir -p -- "$home_dir" "$checkout"
git -C "$checkout" init --quiet
git -C "$checkout" remote add origin "$test_root/origin.git"
HOME=$home_dir XDG_CONFIG_HOME="$home_dir/.config" PATH="$fake_bin:$PATH" sh "$extract_dir/$package_name/install.sh" \
    --repo "$checkout" --github-repository example/repository --reviews-dir "$test_root/reviews" \
    >"$test_root/install.txt" 2>&1 || fail "installing from the archive failed: $(cat "$test_root/install.txt")"
assert_eq "review-pr ${package_version}" "$(HOME=$home_dir PATH="$fake_bin:$PATH" "$home_dir/.local/bin/review-pr" --version)" \
    'the archive installs a working launcher and implementation'
assert_true 'the installation from the archive passes --show-config' \
    env HOME="$home_dir" PATH="$fake_bin:$PATH" "$home_dir/.local/bin/review-pr" --show-config
assert_true 'the installed implementation is byte-for-byte the packaged one' \
    cmp -s "$extract_dir/$package_name/bin/review-pr" "$home_dir/.local/libexec/review-pr/review-pr"

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
