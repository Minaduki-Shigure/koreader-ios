#!/bin/bash

set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <app-asset-dir>" >&2
    exit 1
fi

APP_DIR="$1"

# These source trees implement online-only features and are not referenced by
# the hardened UI. Removing them makes the bundle itself a second security
# boundary if a stale setting or plugin tries to require them by name.
rm -rf \
    "${APP_DIR}/frontend/apps/cloudstorage" \
    "${APP_DIR}/frontend/ui/message" \
    "${APP_DIR}/data/dict" \
    "${APP_DIR}/common/socket" \
    "${APP_DIR}/common/ssl" \
    "${APP_DIR}/common/turbo" \
    "${APP_DIR}/common/zmq"
rm -f \
    "${APP_DIR}/common/socket.lua" \
    "${APP_DIR}/common/ssl.lua" \
    "${APP_DIR}/common/turbo.lua" \
    "${APP_DIR}/common/zmq.lua" \
    "${APP_DIR}/common/lzmq.lua" \
    "${APP_DIR}/frontend/socketutil.lua" \
    "${APP_DIR}/frontend/ui/translator.lua" \
    "${APP_DIR}/frontend/ui/wikipedia.lua" \
    "${APP_DIR}/frontend/ui/downloadmgr.lua" \
    "${APP_DIR}/frontend/ui/otamanager.lua" \
    "${APP_DIR}/frontend/apps/reader/modules/readerwikipedia.lua" \
    "${APP_DIR}/frontend/apps/reader/modules/readerdictionary.lua" \
    "${APP_DIR}/frontend/httpclient.lua" \
    "${APP_DIR}/frontend/ui/network/networklistener.lua" \
    "${APP_DIR}/frontend/ui/network/wpa_supplicant.lua" \
    "${APP_DIR}/ffi/netinfo.lua" \
    "${APP_DIR}/ffi/crypto.lua"

# The strict build has no subprocess-backed dictionary engine. Keep both the
# executable and its GLib runtime out of the final payload as a second boundary
# in case a stale action or future module accidentally becomes reachable.
rm -f "${APP_DIR}/sdcv"

# Base normally stages native Lua modules and shared libraries at a few
# different levels. Match only network/crypto module names, never document
# content, and remove both files and module directories.
while IFS= read -r -d '' path; do
    rm -rf "${path}"
done < <(find "${APP_DIR}" -depth \
    \( -iname 'libssl.*' -o -iname 'libcrypto.*' \
       -o -iname 'libgio*' -o -iname 'libglib*' \
       -o -iname 'libgmodule*' -o -iname 'libgobject*' \
       -o -iname 'libluasocket.*' -o -iname 'libluasec.*' \
       -o -iname 'libzmq.*' -o -iname 'libczmq.*' \
       -o -iname '*zmq*.so' -o -iname '*czmq*.so' \
       -o -iname 'tffi_wrap.*' -o -iname 'turbo.so' \
       -o -iname 'socket.so' -o -iname 'ssl.so' \
       -o -iname '*qtfb*' \) -print0)
