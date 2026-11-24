# Development

## Prerequisites

- Flutter **3.47.8**, Dart **3.13.7** (use the pinned Flutter SDK).
- Android: Java **21**, SDK/Build Tools **36**, NDK **28.2.13676358**, Python
  **3.11** available as `python3.11` (or Gradle property `kindleBuildPython`).
  Minimum Android API is 24. Build the Kindle Python wheels once on Linux with
  `bash tool/android_python/build.sh`, using the Android SDK and NDK above.
  The script writes the wheel directory used by Gradle. CI caches those wheels.
- Windows 10/11 x64: Visual Studio Desktop development with C++, Windows SDK,
  Python 3.11, Chrome and Edge for packaged worker checks. Enable Developer Mode
  for Flutter plugin links. Windows binaries require a Windows host.
- Linux host tests: C compiler (Clang), Python 3.11 and Chromium's system libraries
  for opt-in browser tests. See [testing](TESTING.md).

## Start

From the repository root:

```sh
flutter --version
flutter pub get --enforce-lockfile
python3 tool/preview_metadata.py
python3 tool/prepare_build_metadata.py
flutter analyze
flutter test
flutter run -d <android-device-id>
```

Regenerate `assets/build/source.json` with `prepare_build_metadata.py` before
building a new checkout; this generated file embeds the exact source/version.
See [releasing](RELEASING.md) for publication requirements.

On Windows, use `flutter run -d windows`. Kindle conversion also needs the
separate worker: run `./tool/build_kindle_worker.ps1`, then copy
`artifacts/kindle-dist/KMReader-Kindle` into the built app directory as `kindle/`.
Ordinary Flutter compilation alone does not bundle this executable. CI performs
the copy and includes the matching source archive and notice.

A normal clone uses the prerequisites above; no private workspace setup scripts
are required. Local debug builds use a debug identity and do not need the
project's release signing key. They cannot update the signed public Preview app.
Never copy signing material or local account data into Git.

## Source layout

| Directory | Contents |
|---|---|
| `lib/core/` | Transport, persistence, sync, downloads and service adapters (`kindle/` included) |
| `lib/features/` | Auth, catalog, readers, local/offline library and settings |
| `lib/ui/` | Adaptive shell, theme and shared controls |
| `android/`, `windows/` | Platform hosts and native integration |
| `assets/` | Shipped reader scripts, strings, models, icons and notices |
| `third_party/` | Three locally patched dependency overrides; see each `PORTING.md` |
| `test/`, `integration_test/`, `test_driver/` | Host tests and actual device/WebView checks |
| `tool/` | [Active build, runtime, diagnostic and release tools](../tool/README.md) |
| `docs/` | [User and developer guides](README.md) |

Before moving Python files, read the
[Kindle dependency map](KINDLE_RUNTIME.md). Keep generated output in ignored
`build/`, `artifacts/` and `.dart_tool/`; retain useful builds locally.

## Before integrating changes

```sh
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
python3 tool/preview_metadata.py
python3 -m unittest discover -s tool/tests -v
flutter analyze
flutter test
```

Run the relevant browser, backend and native checks in [testing](TESTING.md).
Do not upgrade dependencies, regenerate icons/models, or bump versions as part
of routine organization. For an actual new distributed update, follow
[releasing](RELEASING.md), including a monotonically increasing build number.
