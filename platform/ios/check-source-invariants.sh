#!/bin/bash

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${PLATFORM_DIR}/../.." && pwd)"
LOADER="${PLATFORM_DIR}/ios_loader.m"
COVER_BROWSER="${REPO_ROOT}/plugins/coverbrowser.koplugin/bookinfomanager.lua"

require_source() {
    local needle="$1"
    if ! grep -Fq -- "${needle}" "${LOADER}"; then
        echo "error: ios_loader.m is missing required source invariant: ${needle}" >&2
        exit 1
    fi
}

reject_source() {
    local needle="$1"
    if grep -Fq -- "${needle}" "${LOADER}"; then
        echo "error: ios_loader.m contains forbidden source pattern: ${needle}" >&2
        exit 1
    fi
}

# argv is untrusted process input. It must be inserted as Lua string values,
# never interpolated into a chunk passed to a Lua parser.
require_source 'lua_createtable(L, argc > 1 ? argc - 1 : 0, 0);'
require_source 'lua_pushstring(L, argv[i]);'
require_source 'lua_rawseti(L, -2, i);'
require_source 'lua_setglobal(L, "arg");'
reject_source 'luaL_dostring'

# CoverBrowser normally changes crengine's process-wide cache from a forked
# worker. iOS runs this work inline, so it must never make that switch.
if ! grep -Fq -- 'if os.getenv("KO_IOS") ~= "1" and not self.cre_cache_overriden then' "${COVER_BROWSER}"; then
    echo "error: CoverBrowser may override the process-wide crengine cache on iOS" >&2
    exit 1
fi

echo "[check-source-invariants] iOS source invariants satisfied"
