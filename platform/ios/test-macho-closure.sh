#!/bin/bash

set -euo pipefail

if [ "${KO_FAKE_TOOL:-}" = "file" ]; then
    fake_tool_dispatch="file"
elif [ "${KO_FAKE_TOOL:-}" = "otool" ]; then
    fake_tool_dispatch="otool"
else
    fake_tool_dispatch=""
fi

fake_file() {
    local path="${2:-}"
    if [ "${NON_MACHO_DEPENDENCY:-0}" = "1" ] \
            && [ "$(basename "${path}")" = "libfixture.dylib" ]; then
        echo "ASCII text"
    else
        echo "Mach-O 64-bit arm64"
    fi
}

fake_otool() {
    local operation="${1:-}"
    local binary="${2:-}"
    local name
    name="$(basename "${binary}")"
    case "${operation}" in
        -l)
            if [ "${OTOOL_L_FAILURE:-0}" = "1" ]; then exit 19; fi
            if [ "${name}" = "KOReader" ]; then
                echo "          cmd LC_RPATH"
                echo "      cmdsize 48"
                if [ "${ESCAPING_RPATH:-0}" = "1" ]; then
                    echo "         path @executable_path/../outside (offset 12)"
                else
                    echo "         path @executable_path/app/libs (offset 12)"
                fi
            fi
            ;;
        -D)
            echo "${binary}:"
            if [ "${name}" = "libfixture.dylib" ]; then
                echo "@rpath/libfixture.dylib"
            fi
            ;;
        -L)
            echo "${binary}:"
            if [ "${name}" = "KOReader" ]; then
                printf '\t%s\n' '@rpath/libfixture.dylib (compatibility version 1.0.0, current version 1.0.0)'
                if [ "${SYSTEM_PATH_TRAVERSAL:-0}" = "1" ]; then
                    printf '\t%s\n' '/System/Library/../../private/escape.dylib (compatibility version 1.0.0, current version 1.0.0)'
                else
                    printf '\t%s\n' '/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)'
                fi
            else
                printf '\t%s\n' '@rpath/libfixture.dylib (compatibility version 1.0.0, current version 1.0.0)'
                printf '\t%s\n' '/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)'
            fi
            ;;
        *) exit 2 ;;
    esac
}

case "${fake_tool_dispatch}" in
    file) fake_file "$@"; exit ;;
    otool) fake_otool "$@"; exit ;;
esac

trap 'status=$?; echo "::error title=Mach-O closure self-test failed::line ${LINENO}: ${BASH_COMMAND} (exit ${status})"; exit "${status}"' ERR

platform_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

app="${tmpdir}/KOReader.app"
mkdir -p "${tmpdir}/bin" "${app}/app/libs"
touch "${app}/KOReader" "${app}/app/libs/libfixture.dylib"
for tool in file otool; do
    {
        echo '#!/bin/bash'
        printf 'KO_FAKE_TOOL=%q exec %q "$@"\n' \
            "${tool}" "${platform_dir}/test-macho-closure.sh"
    } >"${tmpdir}/bin/${tool}"
    chmod +x "${tmpdir}/bin/${tool}"
done

run_check() {
    PATH="${tmpdir}/bin:${PATH}" "${platform_dir}/check-macho-closure.sh" "${app}"
}

run_check >/dev/null

expect_failure() {
    local name="$1"
    shift
    if env "$@" PATH="${tmpdir}/bin:${PATH}" \
            "${platform_dir}/check-macho-closure.sh" "${app}" \
            >"${tmpdir}/${name}.log" 2>&1; then
        echo "Mach-O closure negative fixture unexpectedly passed: ${name}" >&2
        exit 1
    fi
}

expect_failure escaping-rpath ESCAPING_RPATH=1
expect_failure non-macho-dependency NON_MACHO_DEPENDENCY=1
expect_failure system-path-traversal SYSTEM_PATH_TRAVERSAL=1
expect_failure otool-l-failure OTOOL_L_FAILURE=1

echo "Mach-O closure tests: passed"
