#!/bin/bash

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${PLATFORM_DIR}/../.." && pwd)"
TEMPLATE="${PLATFORM_DIR}/Info.plist.in"
OUTPUT="${PLATFORM_DIR}/Info.plist"

release_tag="${1:-${IOS_MARKETING_VERSION:-$(git -C "${REPO_ROOT}" describe --tags --abbrev=0 --match 'v[0-9]*' HEAD)}}"
release_version="${release_tag#v}"

IFS='.' read -r -a components <<<"${release_version}"
if [ "${#components[@]}" -lt 2 ] || [ "${#components[@]}" -gt 3 ]; then
    echo "error: unsupported release version: ${release_tag}" >&2
    exit 1
fi

while [ "${#components[@]}" -lt 3 ]; do
    components+=("0")
done

normalized=()
for component in "${components[@]}"; do
    if [[ ! "${component}" =~ ^[0-9]+$ ]]; then
        echo "error: unsupported release version: ${release_tag}" >&2
        exit 1
    fi
    normalized+=("$((10#${component}))")
done

version="$(IFS=.; echo "${normalized[*]}")"
temporary="${OUTPUT}.tmp"
trap 'rm -f "${temporary}"' EXIT
sed "s|@VERSION@|${version}|g" "${TEMPLATE}" >"${temporary}"
mv "${temporary}" "${OUTPUT}"
trap - EXIT

echo "[*] Generated ${OUTPUT} with version ${version}"
