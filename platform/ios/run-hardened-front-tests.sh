#!/bin/bash

set -euo pipefail

if [ "$#" -lt 3 ] || [ ! -x "$1/spec/runtests" ]; then
    echo "usage: $0 <installed-koreader-dir> <suite> <spec> [spec ...]" >&2
    exit 2
fi

kodir="$1"
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
books_root="$(mktemp -d "${temp_root}/koreader-hardened-books.XXXXXX")"
trap 'rm -rf "${books_root}"' EXIT

# Make must remain a host build. Inject the iOS policy only after Make has
# selected its host toolchain, immediately before the test process starts.
env \
    KO_HARDENED_OFFLINE=1 \
    KO_IOS=1 \
    KO_BOOKS_HOME="${books_root}" \
    "$(dirname "$0")/run-targeted-front-tests.sh" "$@"
