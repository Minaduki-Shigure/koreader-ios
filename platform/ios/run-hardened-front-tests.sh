#!/bin/bash

set -euo pipefail

if [ "$#" -lt 2 ] || [ ! -x "$1/spec/runtests" ]; then
    echo "usage: $0 <installed-koreader-dir> <suite> [spec ...]" >&2
    exit 2
fi

kodir="$1"
shift
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
books_root="$(mktemp -d "${temp_root}/koreader-hardened-books.XXXXXX")"

# Make must remain a host build. Inject the iOS policy only after Make has
# selected its host toolchain, immediately before the test process starts.
exec env \
    KO_HARDENED_OFFLINE=1 \
    KO_IOS=1 \
    KO_BOOKS_HOME="${books_root}" \
    "${kodir}/spec/runtests" "$@"
