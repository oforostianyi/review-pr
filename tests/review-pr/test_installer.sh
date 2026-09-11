#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

test_root=$(portable_mktemp_dir review-pr-installer)
trap 'rm -rf -- "$test_root"' EXIT

package_root="$test_root/package"
prefix="$test_root/prefix"
config_dir="$test_root/config"
review_repo="$test_root/repository"
reviews_dir="$test_root/reviews"
fake_bin="$test_root/bin"
mkdir -p -- \
    "$package_root/bin" \
    "$package_root/config" \
    "$package_root/docs" \
    "$package_root/runners" \
    "$config_dir/skills/claude/custom-review" \
    "$review_repo" \
    "$fake_bin"

cp -- "$repo_root/bin/review-pr" "$package_root/bin/review-pr"
cp -- "$repo_root/config/review-pr.example.json" "$package_root/config/review-pr.example.json"
cp -- "$repo_root/config/review-pr.schema.json" "$package_root/config/review-pr.schema.json"
cp -- "$repo_root/config/review-pr-findings-v1.schema.json" "$package_root/config/review-pr-findings-v1.schema.json"
cp -- "$repo_root/docs/review-pr.md" "$package_root/docs/review-pr.md"
cp -- "$repo_root/docs/review-pr-finding-contract.md" "$package_root/docs/review-pr-finding-contract.md"
cp -- "$repo_root/README.md" "$package_root/README.md"
cp -- "$repo_root/CHANGELOG.md" "$package_root/CHANGELOG.md"
cp -- "$repo_root/VERSION" "$package_root/VERSION"
cp -- "$repo_root/install.sh" "$package_root/install.sh"
cp -- "$repo_root/review-pr-launcher" "$package_root/review-pr-launcher"
cp -- "$repo_root/runners/review-pr-agy" "$package_root/runners/review-pr-agy"
cp -- "$repo_root/runners/review-pr-pi-guard.js" "$package_root/runners/review-pr-pi-guard.js"
chmod +x "$package_root/install.sh" "$package_root/bin/review-pr" "$package_root/runners/review-pr-agy"

git -C "$review_repo" init --quiet
git -C "$review_repo" remote add origin "$test_root/origin.git"
ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"

jq -n \
    --arg old_repo "$test_root/old-repository" \
    --arg old_reviews "$test_root/old-reviews" \
    '{
        agents: {
            personal: {
                label: "Personal agent",
                enabled: true,
                model: "personal-model",
                effort: "custom",
                runner: "/personal/runner",
                instructions: "Never discard this customization."
            }
        },
        reviewers: ["personal", "second"],
        synthesizer: "personal",
        default_repository: "personal-repo",
        repositories: {
            "personal-repo": {github: "personal/project", checkout: $old_repo, profile: "personal-profile"}
        },
        profiles: {
            "personal-profile": {skills: {personal: "my-private-skill"}}
        },
        reviews_directory: $old_reviews,
        language: "EN",
        prompts: {final: ["A private prompt that must survive upgrades."]}
    }' >"$config_dir/config.json"
cp -- "$config_dir/config.json" "$test_root/config-before.json"
printf '%s\n' 'personal skill contents' >"$config_dir/skills/claude/custom-review/SKILL.md"

PATH="$fake_bin:$PATH" sh "$package_root/install.sh" \
    --repo "$review_repo" \
    --github-repository example/repository \
    --prefix "$prefix" \
    --config-dir "$config_dir" \
    --reviews-dir "$reviews_dir" \
    >"$test_root/install-output.txt"

backup_file=$(find "$config_dir/backups" -type f -name 'config-*.json' -print | sed -n '1p')
assert_file_exists "$backup_file" 'installer creates a timestamped configuration backup'
assert_true 'configuration backup is byte-for-byte complete' \
    cmp -s "$test_root/config-before.json" "$backup_file"
assert_eq 'Personal agent' "$(jq -r '.agents.personal.label' "$config_dir/config.json")" \
    'installer preserves personalized agents'
assert_eq 'A private prompt that must survive upgrades.' \
    "$(jq -r '.prompts.final[0]' "$config_dir/config.json")" \
    'installer preserves personalized prompts'
assert_eq 'my-private-skill' \
    "$(jq -r '.profiles["personal-profile"].skills.personal' "$config_dir/config.json")" \
    'installer preserves personalized profile skills'
assert_eq "$review_repo" \
    "$(jq -r '.repositories[.default_repository].checkout' "$config_dir/config.json")" \
    'installer updates only the selected repository checkout'
assert_eq 'example/repository' \
    "$(jq -r '.repositories[.default_repository].github' "$config_dir/config.json")" \
    'installer updates only the selected repository identity'
assert_eq "$reviews_dir" "$(jq -r '.reviews_directory' "$config_dir/config.json")" \
    'installer updates the requested reviews directory'
assert_file_contains "$config_dir/skills/claude/custom-review/SKILL.md" 'personal skill contents' \
    'installer preserves an existing personalized skill'
assert_file_exists "$prefix/bin/review-pr" 'installer writes the launcher under the selected prefix'
assert_file_exists "$prefix/libexec/review-pr/review-pr-pi-guard.js" 'installer writes the Pi tool guard extension beside the implementation'
assert_file_exists "$config_dir/review-pr-findings-v1.schema.json" 'installer writes the finding-contract schema beside user configuration'
assert_file_exists "$prefix/share/review-pr/review-pr-findings-v1.schema.json" 'installer writes the finding-contract schema into shared package data'
assert_file_exists "$prefix/share/doc/review-pr/review-pr-finding-contract.md" 'installer writes the finding-contract design reference'
assert_true 'installed finding-contract schema matches the packaged schema' \
    cmp -s "$package_root/config/review-pr-findings-v1.schema.json" "$config_dir/review-pr-findings-v1.schema.json"

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
