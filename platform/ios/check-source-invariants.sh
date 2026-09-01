#!/bin/bash

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADER="${PLATFORM_DIR}/ios_loader.m"

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

echo "[check-source-invariants] iOS launcher invariants satisfied"
