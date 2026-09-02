#!/bin/bash
# Assemble KOReader.app for iOS from the staging tree at $1.
#
# Mirrors do_mac_bundle.sh but for iOS:
# - Bundle is flat (no Contents/), per iOS conventions.
# - Launcher (ios_loader.m) is compiled here against the iOS SDK.
# - Dylibs live under koreader/libs/ (matches the cwd-relative path
#   in base/ffi/loadlib.lua), with RPATH set on the launcher.
# - Everything is ad-hoc codesigned so iOS will load it.

set -euo pipefail

if [ $# -lt 1 ] || [ ! -d "$1" ]; then
    echo "${0}: usage: $0 <staging-dir>" >&2
    exit 1
fi

STAGING="$1"
STAGING_KOREADER="${STAGING}/koreader"
APP_BUNDLE="${STAGING}/../KOReader.app"
PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${PLATFORM_DIR}/../.." && pwd)"

# Defaults; override from env to retarget.
IOS_PLATFORM="${IOS_PLATFORM:-iphoneos}"
IOS_ARCH="${IOS_ARCH:-arm64}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-14.0}"
IOS_SDK_PATH="$(xcrun --sdk "${IOS_PLATFORM}" --show-sdk-path)"

if [ "${IOS_PLATFORM}" = "iphonesimulator" ]; then
    IOS_TRIPLE="${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
else
    IOS_TRIPLE="${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}"
fi

# LuaJIT was built into base/build/<machine>/staging/{include,lib}.
# We pick those up via the staging tree the parent Makefile points us to.
BASE_BUILD="${REPO_ROOT}/base/build/${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}"
LUA_INCLUDE="${BASE_BUILD}/staging/include/luajit-2.1"
SDL_INCLUDE="${BASE_BUILD}/staging/include"
LIBS_DIR="${BASE_BUILD}/libs"

if [ ! -d "${LUA_INCLUDE}" ]; then
    echo "${0}: missing LuaJIT headers at ${LUA_INCLUDE}" >&2
    exit 1
fi

echo "[*] Building KOReader.app for ${IOS_TRIPLE}"

# Tear down any previous bundle.
# Note: we use `app/` rather than `koreader/` for the assets dir because
# CFBundleExecutable=KOReader collides with `koreader/` on case-insensitive
# APFS (the default).
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/app"

# 1) Compile the launcher.
echo "[*] Compiling launcher (ios_loader.m)"
xcrun --sdk "${IOS_PLATFORM}" clang \
    -target "${IOS_TRIPLE}" \
    -isysroot "${IOS_SDK_PATH}" \
    -fobjc-arc \
    -O2 -g \
    -I "${LUA_INCLUDE}" \
    -I "${SDL_INCLUDE}" \
    -L "${LIBS_DIR}" \
    -L "${BASE_BUILD}/staging/lib" \
    -lluajit \
    -lSDL3 \
    -framework Foundation \
    -framework UIKit \
    -framework CoreFoundation \
    -framework UniformTypeIdentifiers \
    -Wl,-exported_symbol,_ko_ios_import_document_start \
    -Wl,-exported_symbol,_ko_ios_import_document_poll \
    -Wl,-exported_symbol,_ko_ios_get_safe_area_pixels \
    -Wl,-exported_symbol,_ko_ios_lifecycle_start \
    -Wl,-exported_symbol,_ko_ios_lifecycle_stop \
    -Wl,-exported_symbol,_ko_ios_system_appearance_current \
    -Wl,-exported_symbol,_ko_ios_system_appearance_event_type \
    -Wl,-exported_symbol,_ko_ios_system_appearance_start \
    -Wl,-rpath,@executable_path/app/libs \
    -o "${APP_BUNDLE}/KOReader" \
    "${PLATFORM_DIR}/ios_loader.m" \
    "${PLATFORM_DIR}/ios_filepicker.m" \
    "${PLATFORM_DIR}/ios_lifecycle.c" \
    "${PLATFORM_DIR}/ios_system_appearance.m"

# 2) Copy assets.
echo "[*] Copying koreader/ asset tree"
# Use rsync to dereference the symlink farm the build system produces
# in koreader-ios-*/koreader/ into a flat copy iOS will accept.
rsync -aL \
    --exclude '.git' \
    --exclude 'cache' \
    --exclude 'history' \
    --exclude 'screenshots' \
    --exclude 'spec' \
    --exclude 'tools' \
    --exclude 'plugins' \
    --exclude 'patches' \
    --exclude 'update_once.marker' \
    --exclude 'afterupdate.marker' \
    --exclude '*.dSYM' \
    "${STAGING_KOREADER}/" "${APP_BUNDLE}/app/"

"${PLATFORM_DIR}/copy-allowed-plugins.sh" \
    "${STAGING_KOREADER}/plugins" "${APP_BUNDLE}/app/plugins"
rm -rf "${APP_BUNDLE}/app/patches"
rm -f "${APP_BUNDLE}/app/update_once.marker" "${APP_BUNDLE}/app/afterupdate.marker"
"${PLATFORM_DIR}/strip-network-payload.sh" "${APP_BUNDLE}/app"
"${PLATFORM_DIR}/check-bundle-invariants.sh" "${APP_BUNDLE}/app"

# 2.5) Precompile every .lua to LuaJIT bytecode (no-op if there's no
# host luajit available — only a perf optimisation).
"${PLATFORM_DIR}/precompile-lua.sh" "${APP_BUNDLE}/app" || true
"${PLATFORM_DIR}/check-bundle-invariants.sh" "${APP_BUNDLE}/app"

# 3) Generate Info.plist with an Apple-compatible three-component version.
echo "[*] Writing Info.plist"
"${PLATFORM_DIR}/generate-info-plist.sh"
cp "${PLATFORM_DIR}/Info.plist" "${APP_BUNDLE}/Info.plist"

printf 'APPL????' >"${APP_BUNDLE}/PkgInfo"

# 4) Codesign all bundled Mach-O modules, then the app.
echo "[*] Codesigning bundled libraries"
while IFS= read -r -d '' lib; do
    codesign --force --sign - --timestamp=none "${lib}" >/dev/null
done < <(find "${APP_BUNDLE}/app" -type f \
    \( -name '*.dylib' -o -name '*.so' \) -print0)

echo "[*] Codesigning bundle"
codesign --force --sign - --timestamp=none \
    --entitlements "${PLATFORM_DIR}/KOReader.entitlements" \
    "${APP_BUNDLE}"

echo "[*] Built ${APP_BUNDLE}"
file "${APP_BUNDLE}/KOReader"
