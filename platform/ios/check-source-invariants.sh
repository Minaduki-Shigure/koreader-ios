#!/bin/bash

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${PLATFORM_DIR}/../.." && pwd)"
LOADER="${PLATFORM_DIR}/ios_loader.m"
PICKER="${PLATFORM_DIR}/ios_filepicker.m"
PLIST="${PLATFORM_DIR}/Info.plist.in"
PROJECT="${PLATFORM_DIR}/project.yml"
COVER_BROWSER="${REPO_ROOT}/plugins/coverbrowser.koplugin/bookinfomanager.lua"
IMPORT_PLUGIN="${REPO_ROOT}/plugins/iosimporter.koplugin/main.lua"

require_source() {
    local source="$1"
    local needle="$2"
    if ! grep -Fq -- "${needle}" "${source}"; then
        echo "error: ${source} is missing required source invariant: ${needle}" >&2
        exit 1
    fi
}

reject_source() {
    local source="$1"
    local needle="$2"
    if grep -Fq -- "${needle}" "${source}"; then
        echo "error: ${source} contains forbidden source pattern: ${needle}" >&2
        exit 1
    fi
}

# Strict iOS accepts documents only through the private copy-in picker. Process
# arguments must neither become Lua source nor an alternate file-path ingress.
require_source "${LOADER}" 'static void set_empty_lua_args(lua_State *L)'
require_source "${LOADER}" 'lua_createtable(L, 0, 0);'
require_source "${LOADER}" 'set_empty_lua_args(L);'
reject_source "${LOADER}" 'luaL_dostring'
reject_source "${LOADER}" 'lua_pushstring(L, argv['

# App-owned state and books live in private protected storage. Only volatile
# cache is excluded from backup; imported books remain backup eligible.
require_source "${LOADER}" 'NSApplicationSupportDirectory'
require_source "${LOADER}" '@"KOReader"'
require_source "${LOADER}" '@"Data"'
require_source "${LOADER}" '@"Books"'
require_source "${LOADER}" 'NSFileProtectionCompleteUntilFirstUserAuthentication'
require_source "${LOADER}" 'NSURLIsExcludedFromBackupKey'
require_source "${LOADER}" 'setenv("KO_HOME"'
require_source "${LOADER}" 'setenv("KO_BOOKS_HOME"'
require_source "${LOADER}" 'setenv("KO_HARDENED_OFFLINE", "1", 1)'
reject_source "${LOADER}" 'NSDocumentDirectory'

# The picker is a single-file copy-in ingress. It never persists an external
# capability and does all provider I/O off the UIKit thread.
require_source "${PICKER}" 'initForOpeningContentTypes:@[UTTypeData]'
require_source "${PICKER}" 'asCopy:YES'
require_source "${PICKER}" 'picker.modalPresentationStyle = UIModalPresentationFullScreen;'
require_source "${PICKER}" 'NSFileCoordinator'
require_source "${PICKER}" 'startAccessingSecurityScopedResource'
require_source "${PICKER}" 'stopAccessingSecurityScopedResource'
require_source "${PICKER}" 'NSLock'
require_source "${PICKER}" 'dispatch_async(ko_import_io_queue()'
require_source "${PICKER}" 'dispatch_async(dispatch_get_main_queue()'
require_source "${PICKER}" 'NSURLIsRegularFileKey'
require_source "${PICKER}" 'NSURLIsDirectoryKey'
require_source "${PICKER}" 'NSURLIsSymbolicLinkKey'
require_source "${PICKER}" 'lstat('
require_source "${PICKER}" 'moveItemAtURL:temporaryURL'
require_source "${PICKER}" 'ko_ios_import_document_start'
require_source "${PICKER}" 'ko_ios_import_document_poll'
reject_source "${PICKER}" 'UTTypeFolder'
reject_source "${PICKER}" 'asCopy:NO'
reject_source "${PICKER}" 'bookmarkData'
reject_source "${PICKER}" 'URLByResolvingBookmarkData'
reject_source "${PICKER}" '@"lua"'
reject_source "${PICKER}" '@"sh"'
reject_source "${PICKER}" '@"py"'

# Lua independently verifies the returned path is still below private Books.
require_source "${IMPORT_PLUGIN}" 'ko_ios_import_document_start'
require_source "${IMPORT_PLUGIN}" 'ko_ios_import_document_poll'
require_source "${IMPORT_PLUGIN}" 'KO_HARDENED_OFFLINE'
require_source "${IMPORT_PLUGIN}" 'path outside Books'
reject_source "${IMPORT_PLUGIN}" 'pick_folder'
reject_source "${IMPORT_PLUGIN}" 'resolve_bookmark'

# No Files sharing, open-in-place provider paths, or document type argv entry.
if ! grep -A1 -F '<key>UIFileSharingEnabled</key>' "${PLIST}" | grep -Fq '<false/>'; then
    echo "error: UIFileSharingEnabled must be false" >&2
    exit 1
fi
if ! grep -A1 -F '<key>LSSupportsOpeningDocumentsInPlace</key>' "${PLIST}" | grep -Fq '<false/>'; then
    echo "error: LSSupportsOpeningDocumentsInPlace must be false" >&2
    exit 1
fi
reject_source "${PLIST}" '<key>CFBundleDocumentTypes</key>'

# Every native bridge function called through ffi.C remains explicitly exported.
require_source "${PROJECT}" '_ko_ios_import_document_start'
require_source "${PROJECT}" '_ko_ios_import_document_poll'
require_source "${PROJECT}" '_ko_ios_get_safe_area_pixels'

# CoverBrowser normally changes crengine's process-wide cache from a forked
# worker. iOS runs this work inline, so it must never make that switch.
if ! grep -Fq -- 'if os.getenv("KO_IOS") ~= "1" and not self.cre_cache_overriden then' "${COVER_BROWSER}"; then
    echo "error: CoverBrowser may override the process-wide crengine cache on iOS" >&2
    exit 1
fi

echo "[check-source-invariants] iOS launcher, import, and cache invariants satisfied"
