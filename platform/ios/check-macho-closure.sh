#!/bin/bash

set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <KOReader.app>" >&2
    exit 2
fi

for tool in file otool; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "error: required Mach-O inspection tool is missing: ${tool}" >&2
        exit 1
    fi
done

app_dir="$(cd "$1" && pwd -P)"
main_binary="${app_dir}/KOReader"
if [ ! -f "${main_binary}" ]; then
    echo "error: main executable is missing: ${main_binary}" >&2
    exit 1
fi

bundle_files="$(mktemp)"
macho_list="$(mktemp)"
trap 'rm -f "${bundle_files}" "${macho_list}"' EXIT

find "${app_dir}" -type f -print0 >"${bundle_files}"
while IFS= read -r -d '' candidate; do
    description="$(file -b "${candidate}")"
    if printf '%s\n' "${description}" | grep -q 'Mach-O'; then
        printf '%s\n' "${candidate}" >>"${macho_list}"
    fi
done <"${bundle_files}"

if [ ! -s "${macho_list}" ]; then
    echo "error: app bundle has no Mach-O files" >&2
    exit 1
fi

list_rpaths() {
    otool -l "$1" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { want_path = 1; next }
        want_path && $1 == "path" { print $2; want_path = 0 }
    '
}

expand_anchored_path() {
    local value="$1"
    local binary="$2"
    case "${value}" in
        @executable_path*) printf '%s%s\n' "${app_dir}" "${value#@executable_path}" ;;
        @loader_path*) printf '%s%s\n' "$(dirname "${binary}")" "${value#@loader_path}" ;;
        *) return 1 ;;
    esac
}

normalize_absolute_path() {
    awk -v path="$1" 'BEGIN {
        if (substr(path, 1, 1) != "/") exit 1
        count = split(path, parts, "/")
        depth = 0
        for (i = 1; i <= count; i++) {
            if (parts[i] == "" || parts[i] == ".") continue
            if (parts[i] == "..") {
                if (depth == 0) exit 1
                depth--
            } else {
                stack[++depth] = parts[i]
            }
        }
        result = ""
        for (i = 1; i <= depth; i++) result = result "/" stack[i]
        print (result == "" ? "/" : result)
    }'
}

has_unsafe_dependency_syntax() {
    case "$1" in
        *//*) return 0 ;;
    esac
    case "/${1#/}/" in
        */./*|*/../*) return 0 ;;
        *) return 1 ;;
    esac
}

require_bundle_file() {
    local candidate="$1"
    local dependency="$2"
    local binary="$3"
    if [ ! -f "${candidate}" ]; then
        return 1
    fi
    local canonical
    canonical="$(cd "$(dirname "${candidate}")" && pwd -P)/$(basename "${candidate}")"
    case "${canonical}" in
        "${app_dir}"/*)
            if ! file -b "${canonical}" | grep -q 'Mach-O'; then
                echo "error: dependency target is not Mach-O: ${binary}: ${dependency} -> ${canonical}" >&2
                return 2
            fi
            return 0
            ;;
        *)
            echo "error: dependency resolves outside app: ${binary}: ${dependency} -> ${canonical}" >&2
            return 2
            ;;
    esac
}

resolve_from_rpath_owner() {
    local dependency="$1"
    local binary="$2"
    local owner="$3"
    local candidate expanded_rpath rpath rpaths status

    if ! rpaths="$(list_rpaths "${owner}")"; then
        echo "error: cannot inspect LC_RPATH commands: ${owner}" >&2
        return 2
    fi
    while IFS= read -r rpath; do
        [ -n "${rpath}" ] || continue
        if expanded_rpath="$(expand_anchored_path "${rpath}" "${owner}" 2>/dev/null)"; then
            candidate="${expanded_rpath}/${dependency#@rpath/}"
            if require_bundle_file "${candidate}" "${dependency}" "${binary}"; then
                return 0
            else
                status=$?
                if [ "${status}" -eq 2 ]; then return 2; fi
            fi
        fi
    done <<<"${rpaths}"
    return 1
}

resolve_dependency() {
    local dependency="$1"
    local binary="$2"
    local candidate status

    case "${dependency}" in
        /System/Library/*|/usr/lib/*)
            if has_unsafe_dependency_syntax "${dependency}"; then
                echo "error: non-canonical system dependency: ${binary}: ${dependency}" >&2
                return 1
            fi
            return 0
            ;;
        @executable_path/*|@loader_path/*)
            candidate="$(expand_anchored_path "${dependency}" "${binary}")"
            require_bundle_file "${candidate}" "${dependency}" "${binary}"
            return $?
            ;;
        @rpath/*)
            if resolve_from_rpath_owner "${dependency}" "${binary}" "${binary}"; then
                return 0
            else
                status=$?
                if [ "${status}" -eq 2 ]; then return 2; fi
            fi
            if [ "${binary}" != "${main_binary}" ]; then
                if resolve_from_rpath_owner "${dependency}" "${binary}" "${main_binary}"; then
                    return 0
                else
                    status=$?
                    if [ "${status}" -eq 2 ]; then return 2; fi
                fi
            fi
            echo "error: unresolved @rpath dependency: ${binary}: ${dependency}" >&2
            return 1
            ;;
        /*)
            echo "error: non-system absolute dependency: ${binary}: ${dependency}" >&2
            return 1
            ;;
        *)
            echo "error: unsupported relative dependency: ${binary}: ${dependency}" >&2
            return 1
            ;;
    esac
}

while IFS= read -r binary; do
    if ! rpaths="$(list_rpaths "${binary}")"; then
        echo "error: cannot inspect LC_RPATH commands: ${binary}" >&2
        exit 1
    fi
    while IFS= read -r rpath; do
        [ -n "${rpath}" ] || continue
        case "${rpath}" in
            @executable_path/*|@loader_path/*)
                expanded="$(expand_anchored_path "${rpath}" "${binary}")"
                normalized="$(normalize_absolute_path "${expanded}")"
                case "${normalized}" in
                    "${app_dir}"/*) ;;
                    *)
                        echo "error: LC_RPATH escapes app bundle: ${binary}: ${rpath}" >&2
                        exit 1
                        ;;
                esac
                ;;
            *)
                echo "error: unsupported LC_RPATH: ${binary}: ${rpath}" >&2
                exit 1
                ;;
        esac
    done <<<"${rpaths}"

    install_id="$(otool -D "${binary}" 2>/dev/null | sed -n '2p' | sed 's/^[[:space:]]*//')"
    if [ -n "${install_id}" ]; then
        case "${install_id}" in
            @rpath/*|@executable_path/*|@loader_path/*) ;;
            *)
                echo "error: unsupported Mach-O install name: ${binary}: ${install_id}" >&2
                exit 1
                ;;
        esac
        resolve_dependency "${install_id}" "${binary}"
    fi

    otool -L "${binary}" | sed -n '2,$p' | while IFS= read -r line; do
        dependency="$(printf '%s\n' "${line}" | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')"
        [ -n "${dependency}" ] || continue
        resolve_dependency "${dependency}" "${binary}"
    done
done <"${macho_list}"

echo "[check-macho-closure] all Mach-O dependencies resolve inside the app or to iOS system libraries"
