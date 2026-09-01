#!/bin/bash

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${PLATFORM_DIR}/Info.plist.in"
OUTPUT="${PLATFORM_DIR}/Info.plist"
RELEASE_METADATA="${PLATFORM_DIR}/release.json"

IFS=$'\t' read -r version build_version < <(ruby -rjson -e '
  metadata = JSON.parse(File.read(ARGV.fetch(0)))
  values = %w[marketingVersion buildVersion].map do |key|
    value = metadata[key]
    abort "error: release.json is missing #{key}" unless value.is_a?(String) && !value.empty?
    value
  end
  puts values.join("\t")
' "${RELEASE_METADATA}")

requested_version="${1:-${IOS_MARKETING_VERSION:-${version}}}"
release_version="${requested_version#v}"

IFS='.' read -r -a components <<<"${release_version}"
if [ "${#components[@]}" -lt 2 ] || [ "${#components[@]}" -gt 3 ]; then
    echo "error: unsupported release version: ${requested_version}" >&2
    exit 1
fi

while [ "${#components[@]}" -lt 3 ]; do
    components+=("0")
done

normalized=()
for component in "${components[@]}"; do
    if [[ ! "${component}" =~ ^[0-9]+$ ]]; then
        echo "error: unsupported release version: ${requested_version}" >&2
        exit 1
    fi
    normalized+=("$((10#${component}))")
done

normalized_version="$(IFS=.; echo "${normalized[*]}")"
if [ "${normalized_version}" != "${version}" ]; then
    echo "error: requested iOS version ${requested_version} does not match release.json ${version}" >&2
    exit 1
fi
if [[ ! "${build_version}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: unsupported build version: ${build_version}" >&2
    exit 1
fi

temporary="${OUTPUT}.tmp"
trap 'rm -f "${temporary}"' EXIT
sed \
    -e "s|@VERSION@|${version}|g" \
    -e "s|@BUILD_VERSION@|${build_version}|g" \
    "${TEMPLATE}" >"${temporary}"
mv "${temporary}" "${OUTPUT}"
trap - EXIT

echo "[*] Generated ${OUTPUT} with version ${version} (${build_version})"
