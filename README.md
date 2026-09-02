[![KOReader](https://raw.githubusercontent.com/koreader/koreader.github.io/master/koreader-logo.png)](https://koreader.rocks)

> ## Hardened strict-offline iOS / iPadOS port
>
> This branch carries an experimental iPhone and iPad target. It produces an
> unsigned device build suitable for external signing tools such as SideStore,
> or an Xcode project for locally signed development builds. The current port
> is device-only (`arm64`) and uses LuaJIT in interpreter-only mode because the
> iOS sandbox does not permit JIT memory mappings.
>
> The iOS package is deliberately offline-only. It imports individual files,
> file batches, or whole folders by copying supported documents into private
> app storage and omits networking, cloud, OTA update,
> writable plugin, user-patch, and document-sidecar execution paths. The
> upstream feature list below describes KOReader generally; online integrations
> are not present in this iOS package.
>
> Published unsigned builds are available from the shared SideStore/
> LiveContainer source:
>
> `https://raw.githubusercontent.com/Minaduki-Shigure/koreader-ios/refs/heads/ios-release/sidestore-source.json`
>
> Add that URL under **Sources** in LiveContainer to install KOReader as a
> LiveContainer guest. Adding it to SideStore installs KOReader as a standalone
> sideloaded app instead. The source targets arm64 devices running iOS/iPadOS
> 14 or newer and is not an AltStore PAL notarized marketplace source.
> Before importing books in the LiveContainer guest, open KOReader's app-specific
> settings in LiveContainer and enable **Fix File Picker**. A LiveContainer guest
> does not have the same OS-level container isolation as the standalone
> SideStore installation; use the standalone installation when that boundary is
> required.
>
> ```sh
> make TARGET=ios xcodeproj
> ```
>
> See [`doc/Building_iOS.md`](doc/Building_iOS.md) for prerequisites, headless
> builds, bundle layout, and known limitations.

#### KOReader is a document viewer primarily aimed at e-ink readers.

[![AGPL Licence][badge-license]](COPYING)
[![Latest release][badge-release]][link-gh-releases]
[![Gitter][badge-gitter]][link-gitter]
[![Mobileread][badge-mobileread]][link-forum]
[![Build Status][badge-circleci]][link-circleci]
[![Coverage Status][badge-coverage]][link-coverage]
[![Weblate Status][badge-weblate]][link-weblate]

[Download](https://github.com/koreader/koreader/releases) •
[User guide](http://koreader.rocks/user_guide/) •
[Wiki](https://github.com/koreader/koreader/wiki) •
[Developer docs](http://koreader.rocks/doc/)

## Main features

* **portable**: runs on embedded devices (Cervantes, Kindle, Kobo, PocketBook, reMarkable), Android and Linux computers. Developers can run a KOReader emulator in Linux and MacOS.

* **multi-format documents**: supports fixed page formats (PDF, DjVu, CBT, CBZ) and reflowable e-book formats (EPUB, FB2, Mobi, DOC, RTF, HTML, CHM, TXT). Scanned PDF/DjVu documents can also be reflowed with the built-in K2pdfopt library. [ZIP files][link-wiki-zip] are also supported for some formats.

* **full-featured reading**: multi-lingual user interface with a highly customizable reader view and many typesetting options. You can set arbitrary page margins, override line spacing and choose external fonts and styles. It has multi-lingual hyphenation dictionaries bundled into the application.

* **integrated** with *calibre* (search metadata, receive ebooks wirelessly, browse library via OPDS), *Wallabag*, *Wikipedia*, *Google Translate* and other content providers.

* **optimized for e-ink devices**: custom UI without animation, with paginated menus, adjustable text contrast, and easy zoom to fit content or page in paged media.

* **extensible**: via plugins

* **fast**: on some older devices, it has been measured to have less than half the page-turn delay as the built in reading software.

* **and much more**: look up words with StarDict dictionaries / Wikipedia, add your own online OPDS catalogs and RSS feeds, over-the-air software updates, an FTP client, an SSH server, …

Please check the [user guide](http://koreader.rocks/user_guide/) and the [wiki][link-wiki] to discover more features and to help us document them.

## Screenshots

<a href="https://github.com/koreader/koreader-artwork/raw/master/koreader-menu.png"><img src="https://github.com/koreader/koreader-artwork/raw/master/koreader-menu-thumbnail.png" alt="" width="200px"></a>
<a href="https://github.com/koreader/koreader-artwork/raw/master/koreader-footnotes.png"><img src="https://github.com/koreader/koreader-artwork/raw/master/koreader-footnotes-thumbnail.png" alt="" width="200px"></a>
<a href="https://github.com/koreader/koreader-artwork/raw/master/koreader-dictionary.png"><img src="https://github.com/koreader/koreader-artwork/raw/master/koreader-dictionary-thumbnail.png" alt="" width="200px"></a>

## Installation

Please follow the model specific steps for your device:

[Android](https://github.com/koreader/koreader/wiki/Installation-on-Android-devices) •
[Cervantes](https://github.com/koreader/koreader/wiki/Installation-on-BQ-devices) •
[Kindle](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices) •
[Kobo](https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices) •
[Linux](https://github.com/koreader/koreader/wiki/Installation-on-desktop-linux) •
[Pocketbook](https://github.com/koreader/koreader/wiki/Installation-on-PocketBook-devices) •
[reMarkable](https://github.com/koreader/koreader/wiki/Installation-on-Remarkable)


## Development

[Setting up a build environment](doc/Building.md) •
[Collaborating with Git](doc/Collaborating_with_Git.md) •
[Building targets](doc/Building_targets.md) •
[Porting](doc/Porting.md) •
[Developer docs](http://koreader.rocks/doc/)

## Support

KOReader is developed and supported by volunteers all around the world. There are many ways you can help:

- [fix bugs][link-issues-bugs] and [implement new features][link-issues-features]
- [translate the program into your language][link-weblate] or improve an existing translation
- document lesser-known features on the [wiki][link-wiki]
- help others with your knowledge on the [forum][link-forum]

Right now we only support [liberapay](https://liberapay.com/KOReader) donations.

## Contributors

[![Last commit][badge-last-commit]][link-gh-commits]
[![Commit activity][badge-commit-activity]][link-gh-insights]

[badge-bountysource]:https://img.shields.io/bountysource/team/koreader/activity?color=red
[badge-circleci]:https://circleci.com/gh/koreader/koreader.svg?style=shield
[badge-coverage]:https://codecov.io/gh/koreader/koreader/branch/master/graph/badge.svg
[badge-commit-activity]:https://img.shields.io/github/commit-activity/m/koreader/koreader
[badge-gitter]:https://img.shields.io/gitter/room/koreader/koreader?color=red
[badge-last-commit]:https://img.shields.io/github/last-commit/koreader/koreader?color=orange
[badge-license]:https://img.shields.io/github/license/koreader/koreader
[badge-release]:https://img.shields.io/github/release/koreader/koreader.svg
[badge-mobileread]:https://img.shields.io/badge/forum-on_mobileread-lightgrey
[badge-weblate]:https://hosted.weblate.org/widgets/koreader/-/koreader/svg-badge.svg

[link-bountysource]:https://www.bountysource.com/teams/koreader
[link-circleci]:https://circleci.com/gh/koreader/koreader
[link-coverage]:https://codecov.io/gh/koreader/koreader
[link-forum]:http://www.mobileread.com/forums/forumdisplay.php?f=276
[link-gh-commits]:https://github.com/koreader/koreader/commits/master
[link-gh-insights]:https://github.com/koreader/koreader/pulse
[link-gh-releases]:https://github.com/koreader/koreader/releases
[link-gitter]:https://gitter.im/koreader/koreader
[link-issues-bugs]:https://github.com/koreader/koreader/issues?q=is%3Aopen+is%3Aissue+label%3Abug
[link-issues-features]:https://github.com/koreader/koreader/issues?q=is%3Aopen+is%3Aissue+label%3Aenhancement
[link-weblate]:https://hosted.weblate.org/engage/koreader/?utm_source=widget
[link-wiki]:https://github.com/koreader/koreader/wiki
[link-wiki-zip]:https://github.com/koreader/koreader/wiki/ZIP
