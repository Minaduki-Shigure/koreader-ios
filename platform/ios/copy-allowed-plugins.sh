#!/bin/bash

set -euo pipefail

if [ "$#" -ne 2 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <source-plugins-dir> <destination-plugins-dir>" >&2
    exit 1
fi

SOURCE_DIR="$1"
DEST_DIR="$2"
PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOWLIST="${PLATFORM_DIR}/plugin-allowlist.txt"

rm -rf "${DEST_DIR}"
mkdir -p "${DEST_DIR}"

while IFS= read -r plugin || [ -n "${plugin}" ]; do
    case "${plugin}" in
        ""|*/*|.*|*[!A-Za-z0-9_.-]*|*.koplugin.koplugin)
            echo "error: invalid iOS plugin allowlist entry: ${plugin}" >&2
            exit 1
            ;;
        *.koplugin) ;;
        *)
            echo "error: iOS plugin allowlist entry lacks .koplugin suffix: ${plugin}" >&2
            exit 1
            ;;
    esac
    if [ ! -d "${SOURCE_DIR}/${plugin}" ]; then
        echo "error: allowlisted iOS plugin is missing: ${SOURCE_DIR}/${plugin}" >&2
        exit 1
    fi
    mkdir -p "${DEST_DIR}/${plugin}"
    rsync -aL --delete "${SOURCE_DIR}/${plugin}/" "${DEST_DIR}/${plugin}/"
done < "${ALLOWLIST}"
