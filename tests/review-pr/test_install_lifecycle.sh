#!/usr/bin/env bash
# Clean install, repeated install, and uninstall of a staged package in an
# empty HOME, prefix, and configuration directory, without any developer state.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

test_root=$(portable_mktemp_dir review-pr-lifecycle)
trap 'rm -rf -- "$test_root"' EXIT

package_version=$(sed -n '1p' "$repo_root/VERSION")

stage_package() {
    local target=$1

    mkdir -p -- "$target/bin" "$target/config" "$target/docs" "$target/runners"
    cp -- "$repo_root/bin/review-pr" "$target/bin/review-pr"
    cp -- "$repo_root/config/review-pr.example.json" "$repo_root/config/review-pr.schema.json" \
        "$repo_root/config/review-pr-findings-v1.schema.json" "$target/config/"
    cp -- "$repo_root/docs/review-pr.md" "$repo_root/docs/review-pr-finding-contract.md" "$target/docs/"
    cp -- "$repo_root/README.md" "$repo_root/CHANGELOG.md" "$repo_root/VERSION" \
        "$repo_root/install.sh" "$repo_root/uninstall.sh" "$repo_root/review-pr-launcher" "$target/"
    cp -- "$repo_root/runners/review-pr-agy" "$repo_root/runners/review-pr-pi-guard.js" "$target/runners/"
    chmod 0755 "$target/install.sh" "$target/uninstall.sh" "$target/bin/review-pr" "$target/runners/review-pr-agy" "$target/review-pr-launcher"
}

make_review_checkout() {
    local checkout=$1

    mkdir -p -- "$checkout"
    git -C "$checkout" init --quiet
    git -C "$checkout" remote add origin "$test_root/origin.git"
}

package_root="$test_root/package"
stage_package "$package_root"

fake_bin="$test_root/bin"
mkdir -p -- "$fake_bin"
ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"

# An isolated HOME with a prefix containing a space, so the launcher and the
# installer are exercised with a path that needs quoting everywhere.
home_dir="$test_root/home"
prefix="$home_dir/pre fix"
config_dir="$home_dir/.config/review-pr"
review_repo="$test_root/review checkout"
reviews_dir="$test_root/reviews"
mkdir -p -- "$home_dir"
make_review_checkout "$review_repo"

HOME=$home_dir PATH="$fake_bin:$PATH" sh "$package_root/install.sh" \
    --repo "$review_repo" \
    --github-repository example/repository \
    --prefix "$prefix" \
    --config-dir "$config_dir" \
    --reviews-dir "$reviews_dir" \
    >"$test_root/clean-install.txt" 2>"$test_root/clean-install.err" \
    || fail "clean install failed: $(cat "$test_root/clean-install.err")"

assert_file_contains "$test_root/clean-install.txt" "Installed review-pr ${package_version}" \
    'a clean install reports the package version'
assert_false 'a clean install has no configuration to back up' test -e "$config_dir/backups"
for installed in \
    "bin/review-pr" \
    "libexec/review-pr/review-pr" \
    "libexec/review-pr/review-pr-agy" \
    "libexec/review-pr/review-pr-pi-guard.js" \
    "libexec/review-pr/config-path" \
    "share/review-pr/review-pr.example.json" \
    "share/review-pr/review-pr.schema.json" \
    "share/review-pr/review-pr-findings-v1.schema.json" \
    "share/review-pr/VERSION" \
    "share/doc/review-pr/README.md" \
    "share/doc/review-pr/reference.md" \
    "share/doc/review-pr/review-pr-finding-contract.md" \
    "share/doc/review-pr/CHANGELOG.md"; do
    assert_file_exists "$prefix/$installed" "a clean install writes ${installed}"
done
assert_true 'the launcher is executable' test -x "$prefix/bin/review-pr"
assert_true 'the implementation is executable' test -x "$prefix/libexec/review-pr/review-pr"
assert_true 'the AGY runner is executable' test -x "$prefix/libexec/review-pr/review-pr-agy"
assert_eq "$config_dir/config.json" "$(cat "$prefix/libexec/review-pr/config-path")" \
    'the launcher pointer names the installed configuration file'
assert_file_exists "$config_dir/config.json" 'a clean install creates the configuration from the packaged example'
assert_file_exists "$config_dir/review-pr.schema.json" 'a clean install places the configuration schema beside the configuration'
assert_eq 'claude,codex' "$(jq -r '.agents | keys | join(",")' "$config_dir/config.json")" \
    'the default configuration only declares the hosted Claude and Codex agents'
assert_eq 'false' "$(jq 'has("pi") ' <<<"$(jq '.agents' "$config_dir/config.json")")" \
    'the default configuration does not require Pi'
assert_eq '{}' "$(jq -c '.profiles.default.skills' "$config_dir/config.json")" \
    'the default profile requires no review skill'
assert_eq "$review_repo" "$(jq -r '.repositories.repository.checkout' "$config_dir/config.json")" \
    'the default repository points at the requested checkout'
assert_eq 'example/repository' "$(jq -r '.repositories.repository.github' "$config_dir/config.json")" \
    'the default repository records the requested GitHub identity'
assert_eq "$reviews_dir" "$(jq -r '.reviews_directory' "$config_dir/config.json")" \
    'the reviews directory is recorded as requested'
assert_eq 'markdown' "$(jq -r '.reporting.finding_contract.final' "$config_dir/config.json")" \
    'the default configuration keeps the backward-compatible Markdown contract'

assert_eq "review-pr ${package_version}" "$(HOME=$home_dir PATH="$fake_bin:$PATH" "$prefix/bin/review-pr" --version)" \
    'the installed launcher runs the implementation and reports the package version'
HOME=$home_dir PATH="$fake_bin:$PATH" "$prefix/bin/review-pr" --show-config \
    >"$test_root/show-config.txt" 2>"$test_root/show-config.err" \
    || fail "--show-config failed on a clean install: $(cat "$test_root/show-config.err")"
assert_file_contains "$test_root/show-config.txt" "review-pr version: ${package_version}" \
    '--show-config works on a clean install through the launcher and its config pointer'
assert_file_contains "$test_root/show-config.txt" 'Final finding contract: markdown' \
    '--show-config resolves the default reporting configuration'
assert_true 'the launcher accepts an explicit Bash override' \
    env HOME="$home_dir" PATH="$fake_bin:$PATH" REVIEW_PR_BASH="$(command -v bash)" "$prefix/bin/review-pr" --version
assert_true 'the launcher ignores an unusable Bash override and falls back to PATH' \
    env HOME="$home_dir" PATH="$fake_bin:$PATH" REVIEW_PR_BASH=/nonexistent/bash "$prefix/bin/review-pr" --version

# Repeated installation is idempotent: the configuration survives byte for
# byte, every run leaves a distinct backup, and same-second runs do not collide.
cp -- "$config_dir/config.json" "$test_root/config-after-clean-install.json"
for run in 1 2; do
    HOME=$home_dir PATH="$fake_bin:$PATH" sh "$package_root/install.sh" \
        --repo "$review_repo" \
        --github-repository example/repository \
        --prefix "$prefix" \
        --config-dir "$config_dir" \
        --reviews-dir "$reviews_dir" \
        >"$test_root/reinstall-${run}.txt" 2>&1 || fail "reinstall ${run} failed: $(cat "$test_root/reinstall-${run}.txt")"
done
assert_true 'reinstalling with the same options leaves the configuration byte-for-byte unchanged' \
    cmp -s "$test_root/config-after-clean-install.json" "$config_dir/config.json"
assert_eq '2' "$(find "$config_dir/backups" -type f -name 'config-*.json' | wc -l | tr -d ' ')" \
    'every reinstall writes its own backup, even within the same second'
while IFS= read -r backup; do
    assert_true "backup ${backup##*/} is byte-for-byte complete" \
        cmp -s "$test_root/config-after-clean-install.json" "$backup"
done < <(find "$config_dir/backups" -type f -name 'config-*.json')

# Default uninstall removes only package-owned files.
mkdir -p -- "$reviews_dir/example-repository" "$config_dir/skills/claude/team-review"
printf '%s\n' 'a published review artifact' >"$reviews_dir/example-repository/123-final.md"
printf '%s\n' 'team skill' >"$config_dir/skills/claude/team-review/SKILL.md"
printf '%s\n' 'work in progress' >"$review_repo/uncommitted.txt"
HOME=$home_dir sh "$package_root/uninstall.sh" --prefix "$prefix" >"$test_root/uninstall.txt" 2>&1 \
    || fail "uninstall failed: $(cat "$test_root/uninstall.txt")"
assert_file_contains "$test_root/uninstall.txt" 'Configuration was preserved' \
    'the default uninstall states that configuration is preserved'
assert_file_not_exists "$prefix/bin/review-pr" 'uninstall removes the launcher'
assert_false 'uninstall removes the implementation directory' test -e "$prefix/libexec/review-pr"
assert_false 'uninstall removes shared package data' test -e "$prefix/share/review-pr"
assert_false 'uninstall removes packaged documentation' test -e "$prefix/share/doc/review-pr"
assert_file_exists "$config_dir/config.json" 'the default uninstall preserves the configuration'
assert_eq '2' "$(find "$config_dir/backups" -type f -name 'config-*.json' | wc -l | tr -d ' ')" \
    'the default uninstall preserves configuration backups'
assert_file_exists "$config_dir/skills/claude/team-review/SKILL.md" 'the default uninstall preserves portable skills'
assert_file_exists "$reviews_dir/example-repository/123-final.md" 'uninstall never touches published review artifacts'
assert_file_exists "$review_repo/uncommitted.txt" 'uninstall never touches the review checkout'
assert_true 'a repeated uninstall is idempotent' \
    env HOME="$home_dir" sh "$package_root/uninstall.sh" --prefix "$prefix"

# A symlinked launcher target belongs to the user: uninstall removes the link only.
mkdir -p -- "$prefix/bin"
printf '%s\n' 'user script' >"$test_root/user-script.sh"
ln -s "$test_root/user-script.sh" "$prefix/bin/review-pr"
HOME=$home_dir sh "$package_root/uninstall.sh" --prefix "$prefix" >/dev/null 2>&1
assert_file_not_exists "$prefix/bin/review-pr" 'uninstall removes a launcher symlink'
assert_file_exists "$test_root/user-script.sh" 'uninstall does not follow a symlink to a user-owned target'

# --purge-config removes the declared configuration files from the XDG
# location only, and still never touches backups, skills, reviews, or the checkout.
xdg_home="$test_root/xdg"
purge_config_dir="$xdg_home/review-pr"
purge_prefix="$test_root/purge-prefix"
HOME=$home_dir XDG_CONFIG_HOME=$xdg_home PATH="$fake_bin:$PATH" sh "$package_root/install.sh" \
    --repo "$review_repo" \
    --github-repository example/repository \
    --prefix "$purge_prefix" \
    --reviews-dir "$reviews_dir" \
    >"$test_root/purge-install.txt" 2>&1 || fail "install into XDG_CONFIG_HOME failed: $(cat "$test_root/purge-install.txt")"
assert_file_exists "$purge_config_dir/config.json" 'the installer honours XDG_CONFIG_HOME for the configuration directory'
mkdir -p -- "$purge_config_dir/backups" "$purge_config_dir/skills/codex/team-review"
printf '%s\n' '{}' >"$purge_config_dir/backups/config-19700101-000000.json"
printf '%s\n' 'team skill' >"$purge_config_dir/skills/codex/team-review/SKILL.md"
HOME=$home_dir XDG_CONFIG_HOME=$xdg_home sh "$package_root/uninstall.sh" --prefix "$purge_prefix" --purge-config \
    >"$test_root/purge.txt" 2>&1 || fail "purge uninstall failed: $(cat "$test_root/purge.txt")"
assert_file_contains "$test_root/purge.txt" "Removed review-pr and configuration from ${purge_config_dir}" \
    'the purge uninstall names the configuration directory it cleaned'
assert_file_not_exists "$purge_config_dir/config.json" '--purge-config removes the configuration file'
assert_file_not_exists "$purge_config_dir/review-pr.schema.json" '--purge-config removes the configuration schema'
assert_file_not_exists "$purge_config_dir/review-pr-findings-v1.schema.json" '--purge-config removes the finding-contract schema'
assert_file_exists "$purge_config_dir/backups/config-19700101-000000.json" '--purge-config preserves configuration backups'
assert_file_exists "$purge_config_dir/skills/codex/team-review/SKILL.md" '--purge-config preserves portable skills'
assert_file_exists "$reviews_dir/example-repository/123-final.md" '--purge-config never touches published review artifacts'
assert_file_exists "$review_repo/uncommitted.txt" '--purge-config never touches the review checkout'
assert_false 'the purge uninstall removes the package from its prefix' test -e "$purge_prefix/libexec/review-pr"
assert_file_exists "$config_dir/config.json" 'purging one configuration directory leaves another installation configuration alone'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
