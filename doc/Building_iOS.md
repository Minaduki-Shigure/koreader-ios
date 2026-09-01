# Building KOReader for iOS / iPadOS

These instructions cover building the hardened, strict-offline KOReader port
as a sideloadable iOS / iPadOS app from a macOS host. The build cross-compiles
against the iOS SDK shipped with Xcode.

For other targets, see [`Building_targets.md`](Building_targets.md). For
general macOS development setup (the emulator, common prereqs), see
[`Building.md`](Building.md).

## Prerequisites

### macOS + Xcode

You need the full **Xcode** install (App Store or
https://developer.apple.com/xcode/) — the Command-Line Tools alone don't
include the iOS SDK. After installing, run Xcode once to accept the
license, then verify:

```sh
xcrun --sdk iphoneos --show-sdk-path
```

Should print something like `/Applications/Xcode.app/.../iPhoneOS<version>.sdk`.

### Signing and installation

The build can produce an unsigned device bundle without any Apple signing
credentials. SideStore signs that IPA using the account configured on the
device. Direct Xcode installation is also supported: select a free personal
team or a paid Apple Developer team under **Signing & Capabilities**.

### Homebrew packages

Install everything in one command:

```sh
brew install autoconf automake bash binutils cmake coreutils findutils \
    gettext gnu-getopt libtool make meson nasm ninja pkgconf \
    util-linux xcodegen
```

Then put the GNU versions of `make`/`find`/`getopt`/`flock` ahead of the
BSD ones on PATH (KOReader's Makefiles need GNU make ≥ 4.1, GNU
`getopt`, GNU `find`, and `flock` from `util-linux`):

```sh
export PATH="$(brew --prefix)/opt/findutils/libexec/gnubin:$(brew --prefix)/opt/gnu-getopt/bin:$(brew --prefix)/opt/make/libexec/gnubin:$(brew --prefix)/opt/util-linux/bin:${PATH}"
```

Add that line to your shell profile (`~/.zshrc`, `~/.bash_profile`,
etc.) if you're going to be building often.

### Optional: pinned host bytecode compiler

If you build the macOS base first, the iOS build can reuse the host LuaJIT
from the same pinned checkout to precompile bundled `.lua` files. An arbitrary
`luajit` from `PATH` is deliberately not accepted because incompatible
bytecode can make the app fail at launch:

```sh
make TARGET=macos base
```

This is optional. Without that exact host LuaJIT, the build keeps Lua sources.

## Quick verification

There's a preflight script that checks for everything above and reports
any gaps in one pass. The build will run it automatically, but you can
run it standalone:

```sh
./platform/ios/check-prereqs.sh
```

If it prints `[check-prereqs] all required tools present`, you're set.
Otherwise it prints a single `brew install` command listing the missing
packages.

## Build

```sh
git clone --recurse-submodules https://github.com/Minaduki-Shigure/koreader-ios.git
cd koreader-ios
make TARGET=ios xcodeproj
open KOReader.xcodeproj
```

In Xcode:

1. Select the **KOReader** target in the project navigator.
2. **Signing & Capabilities** tab → check *Automatically manage signing*
   → pick your Team.
3. Plug in your iPhone/iPad and trust the Mac when prompted.
4. Choose your device from the run-destination dropdown.
5. Hit ⌘R.

The first launch on the device will require trusting your developer
profile in **Settings → General → VPN & Device Management** on the
phone.

## Headless / CI build

To validate the build without going through Xcode (e.g. as a CI smoke
test, or to verify changes compile before plugging in a device):

```sh
make TARGET=ios xcodeproj
xcodebuild -project KOReader.xcodeproj -scheme KOReader \
    -configuration Debug -destination 'generic/platform=iOS' \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The resulting bundle is
`build/DerivedData/Build/Products/Debug-iphoneos/KOReader.app`. Package its
contents in the standard IPA layout for SideStore:

```sh
mkdir -p build/ipa/Payload
ditto build/DerivedData/Build/Products/Debug-iphoneos/KOReader.app \
    build/ipa/Payload/KOReader.app
(cd build/ipa && zip -qry ../KOReader-unsigned.ipa Payload)
```

The IPA remains unsigned until SideStore installs it. Do not add signing
certificates or provisioning profiles to the repository or CI secrets for an
unsigned build.

The repository's `iOS strict-offline build` GitHub Actions workflow performs
the same device build and uploads the unsigned IPA together with its SHA-256
and validation evidence. Packaging happens only after the source and final app
bundle satisfy the strict-offline checks.

## Strict-offline behavior

- App state lives in `Application Support/KOReader/Data`; imported books live
  in `Application Support/KOReader/Books`. Both are private app-container
  locations with iOS data protection enabled.
- Documents enter through the system picker as copies. File Sharing,
  open-in-place, document-type launch arguments, persistent provider bookmarks,
  and external folder access are disabled.
- File browsing and document launch are confined to the private Books tree,
  including canonical-path and symlink checks. Legacy history, collections,
  shortcuts, and startup state cannot reopen paths outside that tree.
- Networking, TLS, cloud storage, translation, Wikipedia, OPDS/news download,
  synchronization, SSH, and OTA update payloads and UI entry points are
  omitted. CI also rejects native network libraries and socket/DNS imports.
- Only an audited plugin allowlist is packaged. Writable plugins and
  `userpatch` execution are disabled.
- Per-document settings are stored under private app data. Imported
  book-adjacent `.sdr` and legacy Lua sidecars are never executed.
- Copy, move, and rename operations that depend on external `/bin/cp` or
  `/bin/mv` processes are unavailable in the first strict build. Private Books
  import, directory creation, and guarded deletion remain available.

## What's actually built

- **One main exec** (`KOReader`) — compiled from `platform/ios/ios_loader.m`
  + `ios_filepicker.m`, links `libluajit` and `libSDL3`.
- **One monolithic dylib** (`libkoreader-monolibtic.dylib`) — every
  thirdparty C/C++ library KOReader uses, statically linked into a
  single ~17 MiB shared library so iOS does one dyld load + signature
  check at launch instead of 30+.
- **`libluajit.dylib`** — separate so SDL3's iOS launcher can find its
  symbols at startup.
- **`libSDL3.0.dylib`** — separate, holds iOS-specific UIKit code.
- **`app/`** — the Lua frontend tree, all `.lua` files precompiled to
  bytecode (if a host LuaJIT was available).

## Limitations

- **No JIT.** iOS forbids W^X memory pages without a special
  entitlement. We build LuaJIT in interpreter-only mode. KOReader feels
  responsive but heavier Lua codepaths (e.g. cover-browser metadata
  extraction) are slower than on macOS — the cover browser plugin is
  patched to time-slice extraction across `UIManager` ticks rather than
  blocking the UI.
- **PDF reflow (KOPT mode) is disabled.** `libk2pdfopt`'s willuslib
  helpers call `system()`, which iOS marks as unavailable. We patch
  those calls to return 0 at build time so the library compiles, but
  reflow itself is non-functional. Plain PDF rendering via mupdf works.
- **Background extraction can't fork.** iOS sandboxing rejects
  `fork()`. `runInSubProcess` runs work inline on the main thread on
  iOS. A temporary file emulates the one-way child-output pipe; callers asking
  for a bidirectional subprocess pipe receive an explicit unsupported result.
- **No direct external document access.** The system document picker copies one
  supported document at a time into private Books storage. The port does not
  retain security-scoped access to files or folders owned by other providers.
- **Simulator builds are untested.** The `IOS_PLATFORM=iphonesimulator`
  parameter exists in `make/ios.mk` but `base/` would need to be
  rebuilt against the simulator SDK — we haven't wired up an XCFramework.

## Troubleshooting

**`make: *** missing separator. Stop.`** or **`Recipe commences before first target`**

You're hitting macOS' BSD `make` (3.81) instead of GNU `make`. Run the
PATH export from the prereqs section above. Verify with `make --version`
— it should say `GNU Make 4.x` or higher.

**`Could not find Meson`** / **`meson: command not found`**

`brew install meson` (or use the full prereqs list above; meson is in
it).

**`flock: command not found`**

Provided by `util-linux`. Run `brew install util-linux` and add
`$(brew --prefix)/opt/util-linux/bin` to PATH (the export above does
this).

**`xcodegen: command not found`**

`brew install xcodegen`. It's in the full prereqs list above.

**`xcrun: error: SDK "iphoneos" cannot be located`**

You have only the Command-Line Tools, not Xcode. Install Xcode from the
App Store. Then `sudo xcode-select -s /Applications/Xcode.app`.

**Build succeeds but the app crashes on launch with a Lua error**

Likely a stale build artefact. Wipe the per-target build dir and rerun:

```sh
rm -rf base/build/arm64-apple-ios14.0
make TARGET=ios xcodeproj
```

**Cover browser triggers "Start-up of background extraction job failed"**

Shouldn't happen anymore (we patch around it on iOS), but if it does,
the cover browser is still functional — file browsing works, you just
won't see embedded cover thumbnails for new books.

**iOS warns about my dev profile when I tap the app icon**

Settings → General → VPN & Device Management → trust your developer
profile. iOS only asks once per device per Apple ID.

## Reporting build issues

If you hit a problem not covered above, open an issue at
https://github.com/Minaduki-Shigure/koreader-ios/issues with:

- The output of `./platform/ios/check-prereqs.sh`
- Your macOS + Xcode versions (`sw_vers` + `xcodebuild -version`)
- The first error line from the build log
