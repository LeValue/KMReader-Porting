# KMReader for Android and Windows

A Flutter implementation of the [KMReader](https://github.com/kmworks/kmreader)
Komga client, based on upstream commit `e2b35f8796cc830fc6e7464e161b2172d8f916e9`.
The core browsing, reading, download, and progress workflow is implemented.
**Full functional and visual parity has not yet been achieved.** See the
[parity matrix](docs/PARITY.md) for gaps and validation limits.
Current build and test evidence is recorded in [validation results](docs/VALIDATION.md).
The [settings audit](docs/SETTINGS_AUDIT.md) maps upstream reader, theme, cache,
network, translation and appearance preferences to their implementations and
explicit remaining differences.

The Android development APK is available in the
[v0.8.4-preview.1 release](https://github.com/LeValue/KMReader-Porting/releases/tag/v0.8.4-preview.1).
Sign into a GitHub account with access to this private repository before downloading.
In the release's **Assets**, select `KMReader-0.8.4-android-arm64-preview.apk`.
ARMv7 and x86_64 APKs are also available for older devices and emulators. Each APK
is a complete application for its architecture; install only one.
This optimized build installs as **KMReader Preview** alongside the original
debug preview, and updates earlier Preview builds while retaining their local data.
The same release includes `KMReader-0.8.4-windows-x64-preview.zip`: extract the
whole folder and run `KMReader/kmreader.exe` on Windows 10/11 x64. The MSVC runtime
is bundled; the portable Windows build is not Authenticode signed. See [performance changes](docs/PERFORMANCE.md) for cache behavior,
test evidence and device-validation limits.

## Development

Use Flutter **3.47.8** / Dart **3.13.7**. Android builds require Java 21, SDK/Build
Tools 36 and NDK 28.2.13676358; minimum Android version is API 24. Host-side PDF
tests also require a C compiler (Clang on Linux). Windows requires Visual Studio
with Desktop development with C++ and the Windows SDK.

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter run -d <android-device-id>
```

On Windows, run `flutter run -d windows`. CI is configured for Android and
Windows; see [validation results](docs/VALIDATION.md) for observed remote checks.
In the prepared Codex environment, initialize each shell with:

```sh
source /workspace/shared/kmreader-setup/activate.sh
python3 /workspace/shared/kmreader-setup/configure-java-network.py
```

## Real backend validation

```sh
python3 tool/komga_smoke.py --jar /path/to/komga-1.29.1.jar
```

This verifies the official JAR's SHA256, starts a temporary loopback server,
creates random credentials in memory, imports synthetic CBZ/EPUB/PDF fixtures,
and runs the actual Dart client against it. It then stops its process and removes
its files. Existing Komga servers are never modified. The integration test is
skipped in ordinary `flutter test` runs and executed explicitly by this tool and CI.

Other tests cover authentication headers, scoped caches, durable progress,
conflicts, reader anchors/incognito, EPUB parsing, the native PDF engine and
mobile/desktop layouts. Set `KMREADER_SCREENSHOT_DIR` to save visual review
artifacts. These screenshots do not establish pixel parity with the Apple app.

EPUB navigation reads hierarchical EPUB 3 and EPUB 2 indexes, with the spine as
a fallback. Internal links and index entries jump to the target section, including
escaped filenames/fragments. Text changes retain the chapter's scroll fraction;
opening or restyling a chapter does not send new reading progress.

See [preview packaging and publication](docs/RELEASING.md) for versioning, signing
and exact-source CI gates.

## Build

```sh
flutter build apk --debug
flutter build windows --release
```

Android output is `build/app/outputs/flutter-apk/app-debug.apk`, signed with the
development debug key. Windows output is the complete
`build/windows/x64/runner/Release` directory, including DLLs and `data`.
Windows binaries cannot be built on Linux.

For Android release signing, create a git-ignored `android/key.properties` with
`storeFile`, `storePassword`, `keyAlias`, and `keyPassword`, using your own
keystore outside version control. Without that file, release output is unsigned;
the debug key is never silently substituted for release signing.

## Architecture

- `lib/core`: Komga transport, models, SQLite, secure credential vault, server
  selection, offline repository, durable outbox and SSE lifecycle.
- `lib/features`: authentication, dashboard/catalog/details/lists, readers,
  downloads, API keys, settings and library tasks.
- `lib/ui`: adaptive navigation, upstream theme colors and ten-language strings.

Credentials use OS secure storage. Metadata, queries, files and progress are
partitioned by server/account. Downloads retain the source file and comic pages
on disk. Network images are deduplicated while loading without retaining an
entire library in RAM. Redirects do not automatically receive credentials, and
TLS verification stays enabled. HTTP supports local Komga installations.

Progress edits coalesce by book and revision. Acknowledgements cannot delete
newer edits, and newer remote progress requires explicit resolution. EPUB
locators use the server's canonical Readium positions. No production credentials
or demo account are bundled.

MIT; see [LICENSE](LICENSE). Original copyright and artwork attribution are
preserved. Flutter dependencies register their notices in the in-app license
screen; original reference notices remain in `assets/upstream-licenses.json`.

For an isolated local profile or CI startup check, set `KMREADER_DATA_DIR` to
a writable application-data directory before launching. It never changes the
normal profile unless explicitly configured.
