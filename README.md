# KMReader for Android and Windows

[![Build and test](https://github.com/LeValue/KMReader-Porting/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/LeValue/KMReader-Porting/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Read comics and ebooks from **Komga**, your **Kindle account**, or local files
on Android and Windows. This community Flutter port is based on
[KMReader](https://github.com/kmworks/kmreader).

**Development preview:** the current release is **1.0.0 candidate 11, build 41**.
Stable 1.0 and full upstream parity are still in progress. See the
[roadmap](docs/ROADMAP_1.0.md) and [porting checklist](docs/PARITY.md).

## Download and install

**[Download the current Android and Windows preview](https://github.com/LeValue/KMReader-Porting/releases/tag/v1.0.0-candidate.11)**

| Platform | Requirements | Installation |
|---|---|---|
| Android | Android 7.0 / API 24 or later; ARM64, ARMv7 or x86_64 | Download `KMReader-1.0.0-android-universal-preview.apk` and open it. Allow installation from the app you used to download it when Android asks. |
| Windows | Windows 10/11 x64, Microsoft Edge WebView2 Runtime for the ebook reader | Download `KMReader-1.0.0-windows-x64-preview.zip`, extract the **entire** archive and run `KMReader/kmreader.exe`. |

The app installs as **KMReader Preview**. Update the existing installation without
uninstalling to retain its data. The Android APK uses the existing Preview
signing certificate; the Windows bundle includes the MSVC runtime and is not
Authenticode signed. Each release includes `SHA256SUMS.txt` for checking downloads.

From build 35 onward, use **Settings → About → App updates** to get newer public
builds. Android still asks for system installer confirmation. Windows closes the
app, replaces its files with a backup and reopens it. See
[installation and first use](docs/GETTING_STARTED.md) for details.

Build 37 adds recoverable update downloads, clearer failure messages, background
polling fixes and complete Komga cover actions. If an older in-app updater cannot
finish downloading, install this APK over Preview once, without uninstalling;
the corrected updater is available after that installation. [Verification](https://github.com/LeValue/KMReader-Porting/actions/runs/44108656435)
and [delivery](https://github.com/LeValue/KMReader-Porting/actions/runs/44114394009) passed. Physical phone installation/energy acceptance
remains open.

Build 38 offers newer reading positions from Kindle. Automatic resume is off
by default and available in the server settings.

Build 39 fixes the Android certificate check and waits for the Windows update
helper before closing the app. If an earlier build's updater fails, install
this candidate manually once using the instructions above.

Build 40 compares Kindle positions from the downloaded edition and the account.
The two Kindle position switches update immediately in the Servers screen.
Resume asks for confirmation by default.

Build 41 offers the position from a confirmed Kindle conflict in the reader.
Use **Kindle Services** to choose the position for each affected book.

## Features

| Source | Available features |
|---|---|
| Komga | Browse and search libraries, read comics and ebooks, download for offline use, synchronize reading progress, and manage multiple accounts. |
| Local files | Import EPUB, PDF and CBZ/ZIP without an account; read offline and keep progress on the device. |
| Kindle | Connect an Amazon.it account, browse and prepare books for reading, send local documents to the cloud library or selected devices, and manage personal documents. |
| Komga administration | Administrators can edit metadata, select/restore covers, remove uploaded artwork, delete volumes with confirmation, and upload new EPUB/PDF/CBZ/CBR files after server setup. |

Readers include slide and page-curl animations, reading preferences and
bookmarks. The dashboard separates recently added books and comics.

**Komga uploads require the optional [server companion](docs/KOMGA_LIBRARY_MANAGEMENT.md)**
on the server and a reverse proxy under the same Komga address. Metadata,
covers and deletion use Komga's native APIs without the companion. Existing
volume files are never replaced. The upload lifecycle is tested with Komga 1.30.1.

**Kindle support is unofficial** and currently targets Amazon.it. It is not an
Amazon service or an official Kindle client. Amazon-side changes can affect
compatibility. Editing and deletion apply to personal documents, not purchased
books. EPUB replacement can restore verified reading position and bookmarks;
PDFs, notes/highlights and editions that cannot be mapped have additional limits.
Read the [Kindle guide](docs/KINDLE_IMPORT.md) and
[document-management limits](docs/KINDLE_LIBRARY_MANAGEMENT.md) before use.

Local RAR/CBR reading is not implemented; uploading CBR to Komga is a separate
server operation. AI/model-management and translation extensions are future work.
Automated checks do not establish complete upstream parity or performance on
every device; [validation records](docs/VALIDATION.md) list tested behavior and
remaining acceptance checks.

## Documentation and support

- [Install, connect accounts and start reading](docs/GETTING_STARTED.md)
- [Manage a Komga library remotely — Debian setup (Italian)](docs/KOMGA_LIBRARY_MANAGEMENT.md)
- [Send documents to Kindle](docs/KINDLE_IMPORT.md)
- [Documentation index](docs/README.md), [release notes](docs/releases/v1.0.0.md) and [roadmap](docs/ROADMAP_1.0.md)
- [Report a bug or request a feature](https://github.com/LeValue/KMReader-Porting/issues)

Include your app build, operating system, content format and reproduction steps
when reporting a problem. Remove credentials, account details and private server
addresses from logs and screenshots. Use a small, shareable sample when possible;
do not upload copyrighted books without permission.

## Development

Use Flutter **3.47.8** / Dart **3.13.7** and the committed dependency lockfile.
Android builds require Java 21, SDK/Build Tools 36, NDK 28.2.13676358 and Python
3.11. Windows builds require a Windows host with Visual Studio C++ desktop tools.

```sh
git clone https://github.com/LeValue/KMReader-Porting.git
cd KMReader-Porting
flutter pub get --enforce-lockfile
python3 tool/preview_metadata.py
python3 tool/prepare_build_metadata.py
flutter analyze
flutter test
```

Follow [development setup](docs/DEVELOPMENT.md) to run the app, including the
separate Windows Kindle worker. See [testing](docs/TESTING.md),
[contributing](CONTRIBUTING.md) and [build/sign/distribution](docs/RELEASING.md)
for the relevant checks and packaging requirements. Public preview signing keys
are not required for contributions or local debug builds.

## Credits and licenses

Based on [kmworks/kmreader](https://github.com/kmworks/kmreader), using upstream
commit `e2b35f8796cc830fc6e7464e161b2172d8f916e9` as the porting reference.
Application source is distributed under the [MIT license](LICENSE). Third-party
components retain their own licenses; see [upstream notices](assets/upstream-licenses.json),
[Kindle worker notices](assets/kindle/NOTICE.md) and each patched dependency under
[`third_party/`](third_party/). Native distributions include the Kindle worker's
GPL notices and corresponding source.

This project is not affiliated with Amazon or the Komga project. Earlier build
records and experiments remain in the [validation history](docs/VALIDATION.md)
and [archive](archive/README.md).
