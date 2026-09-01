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

### Published SideStore / LiveContainer source

The maintained source URL is:

```text
https://raw.githubusercontent.com/Minaduki-Shigure/koreader-ios/refs/heads/ios-release/sidestore-source.json
```

In LiveContainer 3.7 or newer, open **Sources**, add the URL, and install
KOReader from that listing. This imports KOReader as a LiveContainer guest. A
shortcut using LiveContainer's documented URL scheme is also available after
LiveContainer is installed:

```text
livecontainer://sources?url=https%3A%2F%2Fraw.githubusercontent.com%2FMinaduki-Shigure%2Fkoreader-ios%2Frefs%2Fheads%2Fios-release%2Fsidestore-source.json
```

Adding the same URL to SideStore instead installs KOReader as a normal
standalone sideloaded app. The corresponding SideStore shortcut is:

```text
sidestore://source?url=https%3A%2F%2Fraw.githubusercontent.com%2FMinaduki-Shigure%2Fkoreader-ios%2Frefs%2Fheads%2Fios-release%2Fsidestore-source.json
```

The Release IPA is intentionally unsigned. Do not pre-sign or patch it before
importing it into LiveContainer; LiveContainer performs its own guest patching
and recursively signs the guest Mach-O files in JIT-less mode. On iOS 18, first
import or refresh the certificate from SideStore in LiveContainer, then install
KOReader from LiveContainer's Sources page.

The source format is shared by classic SideStore and LiveContainer. It does not
declare `marketplaceID`, `Build`, or other AltStore PAL notarization fields.

### Using the iOS port

In KOReader's main menu, choose **Import files...** to select one or more
documents, or **Import folder...** to select one or more complete folders.
Imports are copied into the private Books library. A single file can be opened
immediately; a batch or folder opens as a browsable collection. Folder imports
preserve their supported-document hierarchy while hidden files, symbolic
links, packages, sidecars, scripts, unsupported formats, and generic archives
are skipped.

An import accepts at most 64 top-level selections, 512 supported documents,
8192 scanned entries, 2 GiB per file, 4 GiB in total, and 32 directory levels.
Provider or filesystem errors and limit violations roll the entire batch back;
unsupported or unsafe entries are reported as skipped. The app never retains
security-scoped access to the original files or folders.

The allowlisted **Follow system appearance** plugin is enabled by default. It
switches KOReader's night mode when iOS changes between light and dark
appearance, including scheduled system changes while the app is open. Disable
that plugin in **Plugin management** and restart if manual night-mode control
is preferred.

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

## Publishing a source release

`platform/ios/release.json` is the single source of truth for the public app
version, build number, release notes, and iOS release tag; it also records the
audited upstream KOReader tag. Before the
first release, enable **Settings > General > Releases > Enable release
immutability** and set **Settings > Actions > General > Workflow permissions**
to **Read and write permissions**. Immutability only applies to releases made
after that repository setting is enabled, and the workflow refuses to add a
mutable Release to the source.

To prepare a new release:

1. Start from the current `ios-release` branch after its latest source update.
2. Update every field in `platform/ios/release.json`. Both
   `marketingVersion` and the positive integer `buildVersion` must increase.
3. Commit and push the candidate, then wait for the full macOS and iOS workflows
   to pass.
4. Tag that exact commit with the `releaseTag` from the metadata and push the
   tag. Do not reuse or move a published tag.

For an iOS-only maintenance release on the same audited upstream base, these
metadata fields are sufficient. Upgrading the upstream KOReader version also
requires a fresh audit and updates to `IOS_UPSTREAM_TAG`,
`AUDITED_PARENT_BASE`, and `PINNED_BASE_COMMIT` in the workflows.

The tag workflow builds and validates the unsigned IPA, creates a draft GitHub
Release, verifies the uploaded asset's byte size and SHA-256, publishes the
Release, and only then appends the version to `sidestore-source.json`. The final
job fetches both public URLs and repeats the size and digest checks. A failed
build or incomplete Release therefore cannot become the latest source entry.

Do not hand-edit published version entries or replace a Release asset. Classic
AltSources identify updates using `CFBundleShortVersionString`, so every public
release needs a new `marketingVersion`, even when it still uses the same
upstream KOReader tag.

## Strict-offline behavior

- App state lives in `Application Support/KOReader/Data`; imported books live
  in `Application Support/KOReader/Books`. Both are private app-container
  locations with iOS data protection enabled.
- Documents enter through the system picker as bounded file or folder copies.
  File Sharing, open-in-place, document-type launch arguments, persistent
  provider bookmarks, and ongoing external folder access are disabled.
- File browsing and document launch are confined to the private Books tree,
  including canonical-path and symlink checks. Legacy history, collections,
  shortcuts, and startup state cannot reopen paths outside that tree.
- Networking, TLS, cloud storage, translation, Wikipedia, OPDS/news download,
  synchronization, SSH, and OTA update payloads and UI entry points are
  omitted. CI also rejects native network libraries and socket/DNS imports.
- The process-backed StarDict engine is omitted. Local dictionary lookup is
  unavailable because iOS cannot reliably launch the bundled `sdcv`
  executable under this sandbox policy.
- Only an audited plugin allowlist is packaged. Writable plugins and
  `userpatch` execution are disabled.
- Per-document settings are stored under private app data. Imported
  book-adjacent `.sdr` and legacy Lua sidecars are never executed.
- Screenshots are forced into private app data. Arbitrary notebook-file paths
  and custom book-cover files are disabled so stale settings cannot reopen or
  overwrite files outside the private container.
- Global bookmark aggregation and the metadata archive are disabled because
  legacy source folders can point outside Books. Per-book bookmarks,
  highlights, annotations, collections, and reading progress remain available.
- Copy, move, and rename operations that depend on external `/bin/cp` or
  `/bin/mv` processes are unavailable in the first strict build. Private Books
  import, directory creation, and guarded deletion remain available.

## What's actually built

- **One main exec** (`KOReader`) — compiled from `platform/ios/ios_loader.m`,
  `ios_filepicker.m`, and `ios_system_appearance.m`; links `libluajit` and
  `libSDL3`.
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
- **Local dictionary lookup is disabled.** KOReader normally launches `sdcv`
  as a separate process. The strict build removes that executable and its GLib
  dependency, dictionary data, and the reader dictionary module instead of
  exposing an action that cannot run reliably on iOS.
- **No direct external document access.** The system document picker can copy
  bounded selections of supported files or complete folders into private Books
  storage. The port does not retain security-scoped access to files or folders
  owned by other providers.
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
