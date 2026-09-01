#!/bin/bash

set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <app-asset-dir>" >&2
    exit 1
fi

APP_DIR="$1"
PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOWLIST="${PLATFORM_DIR}/plugin-allowlist.txt"

expected="$(mktemp)"
actual="$(mktemp)"
trap 'rm -f "${expected}" "${actual}"' EXIT

LC_ALL=C sort -u "${ALLOWLIST}" > "${expected}"
raw_count="$(grep -cve '^[[:space:]]*$' "${ALLOWLIST}")"
unique_count="$(wc -l < "${expected}" | tr -d ' ')"
if [ "${unique_count}" -eq 0 ] \
        || [ "${raw_count}" -ne "${unique_count}" ]; then
    echo "error: iOS plugin allowlist must contain unique non-empty plugin entries" >&2
    exit 1
fi

if [ ! -d "${APP_DIR}/plugins" ]; then
    echo "error: bundle has no plugins directory" >&2
    exit 1
fi

find "${APP_DIR}/plugins" -mindepth 1 -maxdepth 1 -print |
    while IFS= read -r path; do basename "${path}"; done |
    LC_ALL=C sort -u > "${actual}"

if ! cmp -s "${expected}" "${actual}"; then
    echo "error: bundled plugins do not exactly match the iOS allowlist" >&2
    diff -u "${expected}" "${actual}" >&2 || true
    exit 1
fi

while IFS= read -r plugin; do
    if [ ! -d "${APP_DIR}/plugins/${plugin}" ]; then
        echo "error: allowlisted plugin is not a directory: ${plugin}" >&2
        exit 1
    fi
done < "${expected}"

for forbidden in patches update_once.marker afterupdate.marker; do
    if [ -e "${APP_DIR}/${forbidden}" ]; then
        echo "error: forbidden user-patch/update payload bundled: ${forbidden}" >&2
        exit 1
    fi
done

for forbidden in \
    frontend/socketutil.lua \
    frontend/httpclient.lua \
    frontend/ui/message \
    frontend/ui/network/networklistener.lua \
    frontend/ui/network/wpa_supplicant.lua \
    frontend/ui/translator.lua \
    frontend/ui/wikipedia.lua \
    frontend/ui/downloadmgr.lua \
    frontend/ui/otamanager.lua \
    frontend/apps/cloudstorage \
    frontend/apps/reader/modules/readerwikipedia.lua \
    ffi/netinfo.lua \
    ffi/crypto.lua \
    common/socket common/socket.lua \
    common/ssl common/ssl.lua \
    common/turbo common/turbo.lua \
    common/zmq common/zmq.lua common/lzmq.lua; do
    if [ -e "${APP_DIR}/${forbidden}" ]; then
        echo "error: forbidden online module bundled: ${forbidden}" >&2
        exit 1
    fi
done

if [ ! -f "${APP_DIR}/frontend/ui/network/manager.lua" ]; then
    echo "error: pure offline network manager stub source is missing" >&2
    exit 1
fi

posix_header="${APP_DIR}/ffi/posix_h.lua"
posix_magic=""
if [ -f "${posix_header}" ]; then
    posix_magic="$(LC_ALL=C od -An -tx1 -N3 "${posix_header}" | tr -d ' \n')"
fi
if [ -f "${posix_header}" ] && [ "${posix_magic}" != "1b4c4a" ]; then
    if ! awk '
        /if[[:space:]]+os\.getenv\("KO_HARDENED_OFFLINE"\)[[:space:]]*~=[[:space:]]*"1"[[:space:]]+then/ {
            offline_guard = 1
            next
        }
        offline_guard && /^[[:space:]]*end[[:space:]]*$/ {
            offline_guard = 0
            next
        }
        /(connect|recv|send|sendto|socket|getaddrinfo|getnameinfo|inet_aton|getifaddrs|freeifaddrs|htonl|htons|ntohl|ntohs)[[:space:]]*\(/ {
            if (!offline_guard) {
                print FNR ":" $0 > "/dev/stderr"
                unsafe = 1
            }
        }
        END { exit unsafe }
    ' "${posix_header}"; then
        echo "error: iOS posix FFI payload has unguarded network declarations" >&2
        exit 1
    fi
fi

native_network_payload="$(find "${APP_DIR}" \
    \( -iname 'libssl.*' -o -iname 'libcrypto.*' \
       -o -iname 'libluasocket.*' -o -iname 'libluasec.*' \
       -o -iname 'libzmq.*' -o -iname 'libczmq.*' \
       -o -iname '*zmq*.so' -o -iname '*czmq*.so' \
       -o -iname 'tffi_wrap.*' -o -iname 'turbo.so' \
       -o -iname 'socket.so' -o -iname 'ssl.so' \
       -o -iname '*qtfb*' \) -print -quit)"
if [ -n "${native_network_payload}" ]; then
    echo "error: forbidden native network module bundled: ${native_network_payload}" >&2
    exit 1
fi

echo "[check-bundle-invariants] strict-offline payload satisfied"
