#!/bin/bash

set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${PLATFORM_DIR}/../.." && pwd)"
LOADER="${PLATFORM_DIR}/ios_loader.m"
PICKER="${PLATFORM_DIR}/ios_filepicker.m"
APPEARANCE="${PLATFORM_DIR}/ios_system_appearance.m"
PLIST="${PLATFORM_DIR}/Info.plist.in"
PROJECT="${PLATFORM_DIR}/project.yml"
BUNDLER="${PLATFORM_DIR}/do_ios_bundle.sh"
RELEASE_METADATA="${PLATFORM_DIR}/release.json"
COVER_BROWSER="${REPO_ROOT}/plugins/coverbrowser.koplugin/bookinfomanager.lua"
IMPORT_PLUGIN="${REPO_ROOT}/plugins/iosimporter.koplugin/main.lua"
APPEARANCE_PLUGIN="${REPO_ROOT}/plugins/iossystemappearance.koplugin/main.lua"
PLUGIN_LOADER="${REPO_ROOT}/frontend/pluginloader.lua"
SDL3="${REPO_ROOT}/base/ffi/SDL3.lua"
SDL3_CDECL="${REPO_ROOT}/base/ffi-cdecl/SDL3_decl.c"
SDL3_HEADER="${REPO_ROOT}/base/ffi/SDL3_h.lua"
SDL3_TOUCH_STATE="${REPO_ROOT}/base/ffi/sdl3_touch_state.lua"
SDL3_INPUT="${REPO_ROOT}/base/ffi/input_SDL3.lua"
DEVICE="${REPO_ROOT}/frontend/device/sdl/device.lua"
READER_UI="${REPO_ROOT}/frontend/apps/reader/readerui.lua"
PIC_DOCUMENT="${REPO_ROOT}/frontend/document/picdocument.lua"
KOPT_INTERFACE="${REPO_ROOT}/frontend/document/koptinterface.lua"
FILE_MANAGER="${REPO_ROOT}/frontend/apps/filemanager/filemanager.lua"
BOOK_SHORTCUTS="${REPO_ROOT}/plugins/bookshortcuts.koplugin/main.lua"
COMMON_INFO="${REPO_ROOT}/frontend/ui/elements/common_info_menu_table.lua"
COMMON_SETTINGS="${REPO_ROOT}/frontend/ui/elements/common_settings_menu_table.lua"
DOC_SETTINGS="${REPO_ROOT}/frontend/docsettings.lua"
DOCUMENT_POLICY="${REPO_ROOT}/frontend/document/documentpathpolicy.lua"
DOCUMENT_REGISTRY="${REPO_ROOT}/frontend/document/documentregistry.lua"
FILE_MANAGER_COLLECTION="${REPO_ROOT}/frontend/apps/filemanager/filemanagercollection.lua"
FILE_MANAGER_HISTORY="${REPO_ROOT}/frontend/apps/filemanager/filemanagerhistory.lua"
FILE_MANAGER_SHORTCUTS="${REPO_ROOT}/frontend/apps/filemanager/filemanagershortcuts.lua"
MIGRATIONS="${REPO_ROOT}/frontend/ui/data/onetime_migration.lua"
READER_ENTRY="${REPO_ROOT}/reader.lua"
READER_HIGHLIGHT="${REPO_ROOT}/frontend/apps/reader/modules/readerhighlight.lua"
READER_BOOKMARK="${REPO_ROOT}/frontend/apps/reader/modules/readerbookmark.lua"
READER_ANNOTATION="${REPO_ROOT}/frontend/apps/reader/modules/readerannotation.lua"
SCREENSHOTER="${REPO_ROOT}/frontend/ui/widget/screenshoter.lua"
DISPATCHER="${REPO_ROOT}/frontend/dispatcher.lua"
THIRD_PARTY="${REPO_ROOT}/frontend/device/thirdparty.lua"
INPUT="${REPO_ROOT}/frontend/device/input.lua"
READ_HISTORY="${REPO_ROOT}/frontend/readhistory.lua"
FILE_MANAGER_UTIL="${REPO_ROOT}/frontend/apps/filemanager/filemanagerutil.lua"
FILE_MANAGER_BOOKINFO="${REPO_ROOT}/frontend/apps/filemanager/filemanagerbookinfo.lua"
FILE_MANAGER_SEARCHER="${REPO_ROOT}/frontend/apps/filemanager/filemanagerfilesearcher.lua"
BOOKMARK_BROWSER="${REPO_ROOT}/frontend/ui/widget/bookmarkbrowser.lua"
BOOK_METADATA_ARCHIVE="${REPO_ROOT}/frontend/ui/widget/bookmetadataarchive.lua"
SAFE_SETTINGS="${REPO_ROOT}/frontend/safesettings.lua"
ALLOWLIST="${PLATFORM_DIR}/plugin-allowlist.txt"

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

require_file_source() {
    local file="$1"
    local needle="$2"
    local label="$3"
    if ! grep -Fq -- "${needle}" "${file}"; then
        echo "error: ${label} is missing required source invariant: ${needle}" >&2
        exit 1
    fi
}

reject_file_source() {
    local file="$1"
    local needle="$2"
    local label="$3"
    if grep -Fq -- "${needle}" "${file}"; then
        echo "error: ${label} contains forbidden source pattern: ${needle}" >&2
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
require_source "${LOADER}" 'if (setenv("KO_IOS", "1", 1) != 0'
reject_source "${LOADER}" 'NSDocumentDirectory'

# The picker supports bounded file batches and whole folders, but only as
# private copies. It never persists an external capability and does all
# provider I/O off the UIKit thread.
require_source "${PICKER}" 'KO_IMPORT_SELECT_FILES'
require_source "${PICKER}" 'KO_IMPORT_SELECT_FOLDERS'
require_source "${PICKER}" '? @[UTTypeFolder]'
require_source "${PICKER}" ': @[UTTypeData]'
require_source "${PICKER}" 'initForOpeningContentTypes:contentTypes'
require_source "${PICKER}" 'BOOL copySelection = selectionMode == KO_IMPORT_SELECT_FILES;'
require_source "${PICKER}" 'asCopy:copySelection'
require_source "${PICKER}" 'picker.allowsMultipleSelection = YES;'
require_source "${PICKER}" 'picker.modalPresentationStyle = UIModalPresentationFullScreen;'
require_source "${PICKER}" 'NSFileCoordinator'
require_source "${PICKER}" 'NSFileCoordinatorReadingWithoutChanges'
require_source "${PICKER}" 'NSDirectoryEnumerator<NSURL *>'
require_source "${PICKER}" 'startAccessingSecurityScopedResource'
require_source "${PICKER}" 'stopAccessingSecurityScopedResource'
require_source "${PICKER}" 'NSLock'
require_source "${PICKER}" 'dispatch_async(ko_import_io_queue()'
require_source "${PICKER}" 'dispatch_async(dispatch_get_main_queue()'
require_source "${PICKER}" 'NSURLIsRegularFileKey'
require_source "${PICKER}" 'NSURLIsDirectoryKey'
require_source "${PICKER}" 'NSURLIsSymbolicLinkKey'
require_source "${PICKER}" 'lstat('
require_source "${PICKER}" 'KO_IMPORT_MAX_SELECTED_ITEMS 64U'
require_source "${PICKER}" 'KO_IMPORT_MAX_DOCUMENTS 512U'
require_source "${PICKER}" 'KO_IMPORT_MAX_SCANNED_ITEMS 8192U'
require_source "${PICKER}" 'KO_IMPORT_MAX_DIRECTORY_DEPTH 32U'
require_source "${PICKER}" 'KO_IMPORT_MAX_AGGREGATE_BYTES'
require_source "${PICKER}" 'getenv("KO_HOME")'
require_source "${PICKER}" '@"ImportStaging"'
require_source "${PICKER}" 'initWithUUIDString:uuidString'
require_source "${PICKER}" 'NSURLIsExcludedFromBackupKey'
require_source "${PICKER}" 'requireSecurityScope'
require_source "${PICKER}" 'hasItemSecurityScope'
require_source "${PICKER}" 'if (pickerCopiedSelection) {'
require_source "${PICKER}" 'moveItemAtURL:stageURL'
require_source "${PICKER}" 'moveItemAtURL:temporaryURL'
require_source "${PICKER}" 'ko_ios_import_document_start'
require_source "${PICKER}" 'ko_ios_import_document_poll'
require_source "${PICKER}" 'outImportedCount'
require_source "${PICKER}" 'outSkippedCount'
require_source "${PICKER}" 'outIsCollection'
reject_source "${PICKER}" 'asCopy:NO'
reject_source "${PICKER}" 'bookmarkData'
reject_source "${PICKER}" 'URLByResolvingBookmarkData'
reject_source "${PICKER}" '@"lua"'
reject_source "${PICKER}" '@"sh"'
reject_source "${PICKER}" '@"py"'

# Lua independently verifies the returned path is still below private Books.
require_source "${IMPORT_PLUGIN}" 'ko_ios_import_document_start'
require_source "${IMPORT_PLUGIN}" 'ko_ios_import_document_poll'
require_source "${IMPORT_PLUGIN}" 'KO_IMPORT_SELECT_FILES'
require_source "${IMPORT_PLUGIN}" 'KO_IMPORT_SELECT_FOLDERS'
require_source "${IMPORT_PLUGIN}" 'out_imported_count'
require_source "${IMPORT_PLUGIN}" 'out_skipped_count'
require_source "${IMPORT_PLUGIN}" 'out_is_collection'
require_source "${IMPORT_PLUGIN}" 'libs/libkoreader-lfs'
require_source "${IMPORT_PLUGIN}" 'getCurrentUI'
require_source "${IMPORT_PLUGIN}" 'KO_HARDENED_OFFLINE'
require_source "${IMPORT_PLUGIN}" 'path outside Books'
reject_source "${IMPORT_PLUGIN}" 'resolve_bookmark'

security_scope_start_count="$(grep -Fc -- 'startAccessingSecurityScopedResource' "${PICKER}" || true)"
if [ "${security_scope_start_count}" -lt 2 ]; then
    echo "error: folder import does not scope both the selected root and child documents" >&2
    exit 1
fi

# System appearance changes are observed by UIKit on its main thread, bridged
# through a dynamically allocated SDL event, and applied idempotently in Lua.
# There is no periodic poller and no call into Lua from a UIKit callback.
require_source "${APPEARANCE}" 'NSThread.isMainThread'
require_source "${APPEARANCE}" 'dispatch_sync(dispatch_get_main_queue()'
require_source "${APPEARANCE}" 'registerForTraitChanges:'
require_source "${APPEARANCE}" 'UITraitUserInterfaceStyle.class'
require_source "${APPEARANCE}" 'SDL_RegisterEvents(1)'
require_source "${APPEARANCE}" 'SDL_PushEvent(&event)'
require_source "${APPEARANCE}" 'atomic_exchange_explicit'
require_source "${APPEARANCE}" 'KO_IOS_EXPORT bool ko_ios_system_appearance_start'
require_source "${APPEARANCE}" 'KO_IOS_EXPORT uint32_t ko_ios_system_appearance_event_type'
require_source "${APPEARANCE}" 'KO_IOS_EXPORT int32_t ko_ios_system_appearance_current'
reject_source "${APPEARANCE}" 'NSTimer'
require_source "${SDL3}" 'event.type >= SDL.SDL_EVENT_USER'
require_source "${SDL3}" 'event.type < SDL.SDL_EVENT_LAST'
require_source "${SDL3}" 'code = tonumber(event.user.code)'
require_source "${SDL3}" 'SDL.SDL_SetEventEnabled(SDL.SDL_EVENT_PINCH_BEGIN, false)'
require_source "${SDL3}" 'SDL.SDL_SetEventEnabled(SDL.SDL_EVENT_PINCH_UPDATE, false)'
require_source "${SDL3}" 'SDL.SDL_SetEventEnabled(SDL.SDL_EVENT_PINCH_END, false)'
require_source "${SDL3_CDECL}" 'cdecl_func(SDL_SetEventEnabled)'
require_source "${SDL3_HEADER}" 'void SDL_SetEventEnabled(Uint32, bool);'
require_source "${SDL3}" 'finger_action = touch_state:onCancel'
require_source "${SDL3}" 'return true, {}'
require_source "${SDL3}" 'if touch_state:resetContacts() then'
require_source "${SDL3_TOUCH_STATE}" 'self:_startDiscarding()'
require_source "${SDL3_TOUCH_STATE}" 'return "cancel"'
require_source "${SDL3_TOUCH_STATE}" 'return "consume"'
require_source "${SDL3_INPUT}" 'setMultitouchSuppressed = SDL.setMultitouchSuppressed'
require_source "${INPUT}" 'function Input:setMultitouchSuppressed(suppressed)'
require_source "${DEVICE}" 'UIManager:broadcastEvent(Event:new("HandledAsSwipe"))'
require_source "${DEVICE}" 'device_input:resetState()'
require_source "${READER_UI}" 'Input:setMultitouchSuppressed(Device:isIOS() and self.document.is_txt == true)'
require_source "${READER_UI}" 'Input:setMultitouchSuppressed(false)'
require_source "${READER_UI}" 'file_type == "txt" or file_type == "txt.zip"'
require_source "${PIC_DOCUMENT}" 'target:invertRect(x, y, rect.w, rect.h)'
require_source "${KOPT_INTERFACE}" 'function KoptInterface:isIOSStandaloneImage(doc)'
require_source "${KOPT_INTERFACE}" 'if os.getenv("KO_IOS") ~= "1" then return false end'
require_source "${KOPT_INTERFACE}" 'local ios_standalone_image = self:isIOSStandaloneImage(doc)'
require_source "${KOPT_INTERFACE}" 'if ios_standalone_image then'

reader_ready_line="$(grep -nF 'self:handleEvent(Event:new("ReaderReady"' "${READER_UI}" | head -n1 | cut -d: -f1)"
reader_suppress_line="$(grep -nF 'Input:setMultitouchSuppressed(Device:isIOS() and self.document.is_txt == true)' "${READER_UI}" | head -n1 | cut -d: -f1)"
reader_restore_line="$(grep -nF 'Device:setIgnoreInput(false) -- Allow processing of events (on Android).' "${READER_UI}" | head -n1 | cut -d: -f1)"
if [ -z "${reader_ready_line}" ] || [ -z "${reader_suppress_line}" ] || [ -z "${reader_restore_line}" ] \
        || [ "${reader_ready_line}" -ge "${reader_suppress_line}" ] \
        || [ "${reader_suppress_line}" -ge "${reader_restore_line}" ]; then
    echo "error: TXT multitouch suppression must only be enabled after ReaderReady and before input is restored" >&2
    exit 1
fi
require_source "${APPEARANCE_PLUGIN}" 'KO_HARDENED_OFFLINE'
require_source "${APPEARANCE_PLUGIN}" 'ko_ios_system_appearance_start'
require_source "${APPEARANCE_PLUGIN}" 'controller:syncCurrentAppearance()'
reject_source "${APPEARANCE_PLUGIN}" 'scheduleIn('

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
require_source "${PLIST}" '<string>@VERSION@</string>'
require_source "${PLIST}" '<string>@BUILD_VERSION@</string>'

ruby -rjson -e '
  metadata = JSON.parse(File.read(ARGV.fetch(0)))
  expected_keys = %w[
    buildVersion channel localizedDescription marketingVersion releaseTag upstreamTag
  ]
  abort "release.json keys do not match the release schema" unless metadata.keys.sort == expected_keys

  version = metadata.fetch("marketingVersion")
  build = metadata.fetch("buildVersion")
  upstream = metadata.fetch("upstreamTag")
  release = metadata.fetch("releaseTag")
  channel = metadata.fetch("channel")
  description = metadata.fetch("localizedDescription")

  abort "invalid marketingVersion" unless version.match?(/\A\d+\.\d+\.\d+\z/)
  abort "invalid buildVersion" unless build.match?(/\A[1-9]\d*\z/)
  abort "invalid upstreamTag" unless upstream.match?(/\Av\d{4}\.\d{2}(?:\.\d+)?\z/)
  abort "releaseTag must encode marketingVersion and buildVersion" unless
    release == "ios-v#{version}-b#{build}"
  abort "unsupported release channel" unless %w[beta stable].include?(channel)
  abort "invalid localizedDescription" unless description.is_a?(String) &&
    !description.empty? && description == description.strip
' "${RELEASE_METADATA}"

# Every native bridge function called through ffi.C remains explicitly exported.
require_source "${PROJECT}" '_ko_ios_import_document_start'
require_source "${PROJECT}" 'ENABLE_DEBUG_DYLIB: NO'
require_source "${PROJECT}" '_ko_ios_import_document_poll'
require_source "${PROJECT}" '_ko_ios_get_safe_area_pixels'
require_source "${PROJECT}" 'platform/ios/ios_system_appearance.m'
require_source "${PROJECT}" '_ko_ios_system_appearance_current'
require_source "${PROJECT}" '_ko_ios_system_appearance_event_type'
require_source "${PROJECT}" '_ko_ios_system_appearance_start'
require_source "${BUNDLER}" '"${PLATFORM_DIR}/ios_system_appearance.m"'
require_source "${BUNDLER}" '_ko_ios_system_appearance_current'
require_source "${BUNDLER}" '_ko_ios_system_appearance_event_type'
require_source "${BUNDLER}" '_ko_ios_system_appearance_start'

# CoverBrowser normally changes crengine's process-wide cache from a forked
# worker. iOS runs this work inline, so it must never make that switch.
if ! grep -Fq -- 'if os.getenv("KO_IOS") ~= "1" and not self.cre_cache_overriden then' "${COVER_BROWSER}"; then
    echo "error: CoverBrowser may override the process-wide crengine cache on iOS" >&2
    exit 1
fi

expected_plugins="$(mktemp)"
runtime_plugins="$(mktemp)"
trap 'rm -f "${expected_plugins}" "${runtime_plugins}"' EXIT
LC_ALL=C sort -u "${ALLOWLIST}" > "${expected_plugins}"
sed -n '/local IOS_PLUGIN_ALLOWLIST = {/,/^}/p' "${PLUGIN_LOADER}" |
    sed -n 's/^[[:space:]]*\([A-Za-z0-9_]*\)[[:space:]]*=[[:space:]]*true,.*/\1.koplugin/p' |
    LC_ALL=C sort -u > "${runtime_plugins}"

raw_plugin_count="$(grep -cve '^[[:space:]]*$' "${ALLOWLIST}")"
unique_plugin_count="$(wc -l < "${expected_plugins}" | tr -d ' ')"
if [ "${unique_plugin_count}" -eq 0 ] \
        || [ "${raw_plugin_count}" -ne "${unique_plugin_count}" ]; then
    echo "error: strict iOS allowlist must contain unique non-empty plugin entries" >&2
    exit 1
fi
if ! cmp -s "${expected_plugins}" "${runtime_plugins}"; then
    echo "error: runtime and bundle iOS plugin allowlists differ" >&2
    diff -u "${expected_plugins}" "${runtime_plugins}" >&2 || true
    exit 1
fi
if grep -Fq -- 'movetoarchive.koplugin' "${ALLOWLIST}"; then
    echo "error: subprocess-based movetoarchive plugin is forbidden on strict iOS" >&2
    exit 1
fi
if grep -Fq -- 'japanese.koplugin' "${ALLOWLIST}"; then
    echo "error: subprocess-based Japanese dictionary plugin is forbidden on strict iOS" >&2
    exit 1
fi

while IFS= read -r plugin; do
    plugin_dir="${REPO_ROOT}/plugins/${plugin}"
    if [ ! -d "${plugin_dir}" ]; then
        echo "error: allowlisted plugin source is missing: ${plugin}" >&2
        exit 1
    fi
    for module in socket ssl turbo zmq czmq; do
        if grep -RFq -- "require(\"${module}" "${plugin_dir}" \
                || grep -RFq -- "require('${module}" "${plugin_dir}"; then
            echo "error: allowlisted plugin imports network module ${module}: ${plugin}" >&2
            exit 1
        fi
    done
done < "${expected_plugins}"

ios_probe_line="$(sed -n '/if os.getenv("KO_IOS") == "1" then/=' "${DEVICE}" | head -n1)"
appimage_probe_line="$(sed -n '/if os.getenv("APPIMAGE") then/=' "${DEVICE}" | head -n1)"
if [ -z "${ios_probe_line}" ] || [ -z "${appimage_probe_line}" ] \
        || [ "${ios_probe_line}" -ge "${appimage_probe_line}" ]; then
    echo "error: iOS device probe must run before SDL emulator/desktop probes" >&2
    exit 1
fi
if ! grep -Fq -- 'return os.getenv("KO_HARDENED_OFFLINE") == "1"' "${DEVICE}"; then
    echo "error: iOS hardened capability does not use KO_HARDENED_OFFLINE" >&2
    exit 1
fi
emulator_guard="$({ sed -n '/Hardened iOS ignores emulator-controlled environment input\./,/self\.hasClipboard = yes/p' "${DEVICE}" || true; })"
if ! grep -Fq -- 'if not self:isHardenedOffline() then' <<< "${emulator_guard}" \
        || ! grep -Fq -- 'loadstring("return " .. viewport)' <<< "${emulator_guard}"; then
    echo "error: hardened iOS does not isolate SDL emulator environment input" >&2
    exit 1
fi
if ! grep -Fq -- 'local NetInfo = not is_hardened_ios and require("ffi/netinfo")' \
        "${REPO_ROOT}/frontend/device/generic/device.lua"; then
    echo "error: generic device eagerly loads netinfo on hardened iOS" >&2
    exit 1
fi
if ! grep -Fq -- 'local ReaderWikipedia = not Device:isHardenedOffline() and require("apps/reader/modules/readerwikipedia")' "${READER_UI}" \
        || ! grep -Fq -- 'local ReaderWikipedia = not Device:isHardenedOffline() and require("apps/reader/modules/readerwikipedia")' "${FILE_MANAGER}"; then
    echo "error: Wikipedia module may be loaded by the hardened UI" >&2
    exit 1
fi
if ! grep -Fq -- 'local ReaderDictionary = not Device:isHardenedOffline() and require("apps/reader/modules/readerdictionary")' "${READER_UI}" \
        || ! grep -Fq -- 'local ReaderDictionary = not Device:isHardenedOffline() and require("apps/reader/modules/readerdictionary")' "${FILE_MANAGER}" \
        || ! grep -Fq -- 'local ReaderDictionary = not Device:isHardenedOffline() and require("apps/reader/modules/readerdictionary")' "${DISPATCHER}"; then
    echo "error: subprocess-backed dictionary module may be loaded by the hardened UI" >&2
    exit 1
fi
require_file_source "${DISPATCHER}" 'show_network_info = {category="none", event="ShowNetworkInfo", title=_("Show network info"), device=true, separator=true, condition=not Device:isHardenedOffline()}' "dispatcher"
if ! grep -Fq -- 'if os.getenv("KO_IOS") == "1" and os.getenv("KO_HARDENED_OFFLINE") == "1" then' \
        "${REPO_ROOT}/frontend/userpatch.lua"; then
    echo "error: userpatch is not fail-closed for hardened iOS" >&2
    exit 1
fi

# Every persisted or direct open path must converge on the canonical Books
# policy. The registry is the final rendering boundary; the UI guards provide
# deterministic fallback before destructive teardown or auxiliary viewers.
require_file_source "${DOCUMENT_POLICY}" 'local canonical = path and ffiUtil.realpath(path)' "document path policy"
require_file_source "${DOCUMENT_POLICY}" 'util.stringStartsWith(canonical, root .. "/")' "document path policy"
require_file_source "${DOCUMENT_POLICY}" 'local function hasSymlinkComponent(path, root)' "document path policy"
require_file_source "${DOCUMENT_POLICY}" 'lfs.symlinkattributes(current, "mode") == "link"' "document path policy"
reject_file_source "${DOCUMENT_POLICY}" 'registerInternalDocument' "document path policy"
require_file_source "${DOCUMENT_REGISTRY}" 'DocumentPathPolicy:resolveDocument(file)' "document registry"
require_file_source "${READER_UI}" 'DocumentPathPolicy:resolveDocument(file)' "reader UI"
search_boundary_count="$(grep -Fc -- 'FileSearcher.search_path = filemanagerutil.constrainToHome(FileSearcher.search_path)' "${FILE_MANAGER_SEARCHER}" || true)"
if [ "${search_boundary_count}" -lt 2 ]; then
    echo "error: file search root is not constrained to Books" >&2
    exit 1
fi
require_file_source "${FILE_MANAGER_SEARCHER}" 'local path_allowed = filemanagerutil.isPathInsideHome(fullpath)' "file search traversal"
require_file_source "${FILE_MANAGER_SEARCHER}" 'local path = filemanagerutil.resolveDocumentPath(item.path)' "file search result"
require_file_source "${READER_ENTRY}" 'DocumentPathPolicy:resolveDocument(last_file)' "reader startup"
require_file_source "${READER_ENTRY}" 'G_reader_settings:delSetting("lastfile")' "reader startup"
require_file_source "${READER_ENTRY}" 'G_reader_settings:saveSetting("start_with", start_with)' "reader startup"
require_file_source "${FILE_MANAGER_HISTORY}" 'filemanagerutil.isPathInsideHome(v.file)' "history boundary"
require_file_source "${FILE_MANAGER_COLLECTION}" 'filemanagerutil.isPathInsideHome(item.file)' "collection boundary"
require_file_source "${FILE_MANAGER_SHORTCUTS}" 'filemanagerutil.isPathInsideHome(folder)' "folder shortcut boundary"
require_file_source "${BOOK_SHORTCUTS}" 'if not filemanagerutil.isPathInsideHome(path) then return end' "book shortcut boundary"
require_file_source "${FILE_MANAGER}" 'filemanagerutil.isPathInsideHome(selected_file)' "selected-file boundary"
require_file_source "${FILE_MANAGER}" 'ok = purgeHardenedDirectory(file)' "recursive delete boundary"
reject_file_source "${FILE_MANAGER}" 'Device:isHardenedOffline() and purgeHardenedDirectory(file) or ffiUtil.purgeDir(file)' "recursive delete boundary"
reject_file_source "${READ_HISTORY}" 'hardened_offline and DocumentPathPolicy:resolveDocument' "history boundary"
require_file_source "${READ_HISTORY}" 'file_path = DocumentPathPolicy:resolveDocument(input_file)' "history boundary"

subprocess_fail_closed_count="$(grep -Fc -- 'if Device:isHardenedOffline() then return false end' "${FILE_MANAGER}" || true)"
if [ "${subprocess_fail_closed_count}" -lt 8 ]; then
    echo "error: subprocess-backed file operations are not all fail-closed" >&2
    exit 1
fi

quickstart_guard="$({ sed -n '/if not Device:isHardenedOffline() then/,/common_info.quickstart_guide = {/p' "${COMMON_INFO}" || true; })"
if ! grep -Fq -- 'common_info.quickstart_guide = {' <<< "${quickstart_guard}"; then
    echo "error: QuickStart remains reachable in hardened iOS" >&2
    exit 1
fi
reject_file_source "${REPO_ROOT}/frontend/ui/quickstart.lua" 'registerInternalDocument' "QuickStart"

require_file_source "${DOC_SETTINGS}" 'if hardened_offline then return { "hash" } end' "DocSettings"
require_file_source "${DOC_SETTINGS}" 'return SafeSettings.loadTable(path)' "DocSettings"
require_file_source "${SAFE_SETTINGS}" 'pcall(jit_control.off, chunk, true)' "safe settings JIT guard"
require_file_source "${SAFE_SETTINGS}" 'debug.sethook(instructionHook, "", HOOK_INTERVAL)' "safe settings instruction guard"
require_file_source "${DOC_SETTINGS}" 'local candidates_list = hardened_offline and {' "DocSettings"
require_file_source "${DOC_SETTINGS}" 'if file_path ~= ""' "DocSettings candidates"
require_file_source "${DOC_SETTINGS}" 'and (not hardened_offline or isPrivateMetadataPath(file_path))' "DocSettings candidates"
candidate_builder="$({ sed -n '/local function buildCandidates/,/local function getOrderedLocationCandidates/p' "${DOC_SETTINGS}" || true; })"
candidate_private_guard_line="$(grep -nF -- 'isPrivateMetadataPath(file_path)' <<< "${candidate_builder}" | head -n1 | cut -d: -f1)"
candidate_file_probe_line="$(grep -nF -- 'isFile(file_path)' <<< "${candidate_builder}" | head -n1 | cut -d: -f1)"
if [ -z "${candidate_private_guard_line}" ] || [ -z "${candidate_file_probe_line}" ] \
        || [ "${candidate_private_guard_line}" -ge "${candidate_file_probe_line}" ]; then
    echo "error: DocSettings probes a candidate before checking its private canonical path" >&2
    exit 1
fi
private_candidate_guard_count="$(grep -Fc -- 'not hardened_offline or isPrivateMetadataPath(candidate_path)' "${DOC_SETTINGS}" || true)"
if [ "${private_candidate_guard_count}" -lt 2 ]; then
    echo "error: DocSettings candidate reads or deletion may escape private metadata storage" >&2
    exit 1
fi
require_file_source "${COMMON_SETTINGS}" 'common_settings.document_metadata_location = nil' "metadata menu"
require_file_source "${COMMON_SETTINGS}" 'common_settings.document_metadata_arc = nil' "metadata menu"
require_file_source "${MIGRATIONS}" 'if last_migration_date < 20220930 and not Device:isHardenedOffline() then' "legacy defaults migration"
require_file_source "${THIRD_PARTY}" 'if hardened_offline then' "third-party integration"
require_file_source "${THIRD_PARTY}" 'o.dicts = {}' "third-party integration"
require_file_source "${INPUT}" 'if os.getenv("KO_HARDENED_OFFLINE") ~= "1" then' "custom input map"
require_file_source "${FILE_MANAGER_UTIL}" 'if Device:isHardenedOffline() then return false end' "script execution"

require_file_source "${SCREENSHOTER}" 'local screenshot_dir = DataStorage:getDataDir() .. "/screenshots"' "screenshot storage"
require_file_source "${SCREENSHOTER}" 'if Device:isHardenedOffline() or not screenshot_name then' "screenshot storage"
require_file_source "${SCREENSHOTER}" 'if Device:isHardenedOffline() then return false end' "screenshot folder chooser"
require_file_source "${READER_ANNOTATION}" 'if not dir or not DocSettings.preparePrivateMetadataDir(dir) then return end' "annotation export"
require_file_source "${READER_BOOKMARK}" 'table.remove(menu_items.bookmarks_settings.sub_item_table)' "annotation export menu"
require_file_source "${FILE_MANAGER_BOOKINFO}" 'if is_file and not Device:isHardenedOffline() then' "notebook metadata"
require_file_source "${FILE_MANAGER_BOOKINFO}" 'if Device:isHardenedOffline() then return false end' "custom cover and notebook actions"
bookmark_browser_guard_count="$(grep -Fc -- 'if Device:isHardenedOffline() then return false end' "${BOOKMARK_BROWSER}" || true)"
if [ "${bookmark_browser_guard_count}" -lt 2 ]; then
    echo "error: global bookmark browser is reachable in hardened iOS" >&2
    exit 1
fi
require_file_source "${BOOK_METADATA_ARCHIVE}" 'if Device:isHardenedOffline() then return false end' "metadata archive"
require_file_source "${FILE_MANAGER_COLLECTION}" 'enabled = not Device:isHardenedOffline() and not button_disabled' "bookmark browser action"
require_file_source "${DISPATCHER}" 'book_metadata_archive = {category="none", event="ShowBookMetadataArchive", title=_("Book metadata archive"), general=true, condition=not Device:isHardenedOffline()}' "dispatcher"
require_file_source "${DISPATCHER}" 'bookmark_browser = {category="none", event="ShowBookmarkBrowser", title=_("Bookmark browser"), general=true, separator=true, condition=not Device:isHardenedOffline()}' "dispatcher"
require_file_source "${DISPATCHER}" 'notebook_file = {category="none", event="ShowNotebookFile", title=_("Notebook file"), general=true, condition=not Device:isHardenedOffline()}' "dispatcher"

# Keep ordinary platforms byte-for-byte compatible in action ordering.
require_file_source "${READER_HIGHLIGHT}" 'table.insert(long_press_action, 6, {_("Translate"), "translate"})' "ReaderHighlight"
require_file_source "${READER_HIGHLIGHT}" 'table.insert(long_press_action, 7, {_("Wikipedia"), "wikipedia"})' "ReaderHighlight"
require_file_source "${READER_HIGHLIGHT}" 'table.insert(long_press_action, 8, {_("Dictionary"), "dictionary"})' "ReaderHighlight"
dictionary_guard_count="$(grep -Fc -- 'if not self.ui.dictionary then return false end' "${READER_HIGHLIGHT}" || true)"
if [ "${dictionary_guard_count}" -lt 2 ]; then
    echo "error: ReaderHighlight dictionary paths are not fail-closed" >&2
    exit 1
fi

for bundler in do_ios_bundle.sh embed-bundle-payload.sh; do
    if ! grep -Fq -- 'copy-allowed-plugins.sh' "${PLATFORM_DIR}/${bundler}" \
            || ! grep -Fq -- 'strip-network-payload.sh' "${PLATFORM_DIR}/${bundler}" \
            || ! grep -Fq -- 'check-bundle-invariants.sh' "${PLATFORM_DIR}/${bundler}"; then
        echo "error: ${bundler} does not enforce the strict payload pipeline" >&2
        exit 1
    fi
    first_check_line="$(grep -nF -- 'check-bundle-invariants.sh' "${PLATFORM_DIR}/${bundler}" | head -n1 | cut -d: -f1)"
    last_check_line="$(grep -nF -- 'check-bundle-invariants.sh' "${PLATFORM_DIR}/${bundler}" | tail -n1 | cut -d: -f1)"
    precompile_line="$(grep -nF -- 'precompile-lua.sh' "${PLATFORM_DIR}/${bundler}" | tail -n1 | cut -d: -f1)"
    if [ "${first_check_line}" -ge "${precompile_line}" ] \
            || [ "${last_check_line}" -le "${precompile_line}" ]; then
        echo "error: ${bundler} must check source before and payload after Lua precompilation" >&2
        exit 1
    fi
done

echo "[check-source-invariants] iOS source invariants satisfied"
