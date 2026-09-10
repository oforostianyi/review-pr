#!/bin/sh

set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
repository_root=$(CDPATH= cd "${script_dir}/.." && pwd -P)
version=$(sed -n '1p' "${repository_root}/VERSION")
case $version in
    ''|*[!0-9A-Za-z.-]*) printf 'Invalid package version: %s\n' "$version" >&2; exit 1 ;;
esac

implementation_version=$(sed -n 's/^readonly REVIEW_PR_VERSION="\([^"]*\)"$/\1/p' "${repository_root}/bin/review-pr")
[ "$implementation_version" = "$version" ] || {
    printf 'Package VERSION (%s) does not match bin/review-pr (%s)\n' "$version" "${implementation_version:-missing}" >&2
    exit 1
}

package_name=review-pr-${version}
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/review-pr-package.XXXXXX")
package_root=${staging_root}/${package_name}
cleanup() {
    rm -rf "$staging_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "${package_root}/bin" "${package_root}/config" "${package_root}/docs" "${package_root}/runners" "${repository_root}/dist"
cp "${repository_root}/bin/review-pr" "${package_root}/bin/review-pr"
cp "${repository_root}/config/review-pr.example.json" "${package_root}/config/review-pr.example.json"
cp "${repository_root}/config/review-pr.schema.json" "${package_root}/config/review-pr.schema.json"
cp "${repository_root}/config/review-pr-findings-v1.schema.json" "${package_root}/config/review-pr-findings-v1.schema.json"
cp "${repository_root}/docs/review-pr.md" "${package_root}/docs/review-pr.md"
cp "${repository_root}/docs/review-pr-finding-contract.md" "${package_root}/docs/review-pr-finding-contract.md"
cp "${repository_root}/runners/review-pr-agy" "${package_root}/runners/review-pr-agy"
cp "${repository_root}/CHANGELOG.md" "${package_root}/CHANGELOG.md"
cp "${repository_root}/README.md" "${package_root}/README.md"
cp "${repository_root}/install.sh" "${package_root}/install.sh"
cp "${repository_root}/uninstall.sh" "${package_root}/uninstall.sh"
cp "${repository_root}/review-pr-launcher" "${package_root}/review-pr-launcher"
cp "${repository_root}/VERSION" "${package_root}/VERSION"
chmod 0755 "$package_root" "${package_root}/bin" "${package_root}/config" "${package_root}/docs" "${package_root}/runners"
chmod 0755 "${package_root}/bin/review-pr" "${package_root}/runners/review-pr-agy" "${package_root}/install.sh" "${package_root}/uninstall.sh" "${package_root}/review-pr-launcher"
chmod 0644 "${package_root}/VERSION" "${package_root}/README.md" "${package_root}/CHANGELOG.md" "${package_root}/config/review-pr.example.json" "${package_root}/config/review-pr.schema.json" "${package_root}/config/review-pr-findings-v1.schema.json" "${package_root}/docs/review-pr.md" "${package_root}/docs/review-pr-finding-contract.md"

archive=${repository_root}/dist/${package_name}.tar.gz
if tar --version 2>/dev/null | grep -q GNU; then
    tar --owner=0 --group=0 --numeric-owner -C "$staging_root" -czf "$archive" "$package_name"
else
    COPYFILE_DISABLE=1 tar -C "$staging_root" -czf "$archive" "$package_name"
fi
chmod 0644 "$archive"

if command -v sha256sum >/dev/null 2>&1; then
    (cd "${repository_root}/dist" && sha256sum "${package_name}.tar.gz" >"${package_name}.tar.gz.sha256")
elif command -v shasum >/dev/null 2>&1; then
    (cd "${repository_root}/dist" && shasum -a 256 "${package_name}.tar.gz" >"${package_name}.tar.gz.sha256")
else
    printf '%s\n' 'WARNING: neither sha256sum nor shasum is available; checksum not created.' >&2
fi

printf '%s\n' "$archive"
