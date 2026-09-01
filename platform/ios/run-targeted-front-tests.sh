#!/bin/bash

set -euo pipefail

if [ "$#" -lt 3 ] || [ ! -x "$1/spec/runtests" ]; then
    echo "usage: $0 <installed-koreader-dir> <suite> <spec> [spec ...]" >&2
    exit 2
fi

kodir="$1"
shift
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
report="$(mktemp "${temp_root}/koreader-targeted-tests.XXXXXX")"
trap 'rm -f "${report}"' EXIT

status=0
"${kodir}/spec/runtests" --busted --output="${report}" "$@" || status=$?
if [ "${status}" -ne 0 ]; then
    exit "${status}"
fi

if [ ! -s "${report}" ] || ! grep -Fq '<testcase' "${report}"; then
    echo "error: targeted frontend command completed without running a test" >&2
    exit 1
fi

test_count="$(grep -Fc '<testcase' "${report}")"
echo "[run-targeted-front-tests] executed ${test_count} test case(s)"
