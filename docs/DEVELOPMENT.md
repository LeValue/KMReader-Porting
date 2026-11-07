# Development

The current source is the **1.0.0+30 candidate** in both `pubspec.yaml` and
`lib/core/app_version.dart`, based on the working 0.9.1 baseline. See the
[release notes](releases/v1.0.0.md) and [readiness work](ROADMAP_1.0.md).

## Prerequisites

- Flutter **3.47.8**, Dart **3.13.7** (use the pinned Flutter SDK).
- Android: Java **21**, SDK/Build Tools **36**, NDK **28.2.13676358**, Python
  **3.11** available as `python3.11` (or Gradle property `kindleBuildPython`).
  Minimum Android API is 24. Chaquopy 17.2.0 installs its pinned native wheels.
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
flutter analyze
flutter test
flutter run -d <android-device-id>
```

On Windows, use `flutter run -d windows`. Kindle conversion also needs the
separate worker: run `./tool/build_kindle_worker.ps1`, then copy
`artifacts/kindle-dist/KMReader-Kindle` into the built app directory as `kindle/`.
Ordinary Flutter compilation alone does not bundle this executable. CI performs
the copy and includes the matching source archive and notice.

For the prepared cloud workspace only, each shell can start with:

```sh
source /workspace/shared/kmreader-setup/activate.sh
python3 /workspace/shared/kmreader-setup/configure-java-network.py
```

These external setup helpers are conveniences, not requirements for a normal
clone. Never copy signing files or local application data into the repository.

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
| `docs/` | [Current guides and versioned evidence](README.md) |
| `archive/` | Superseded standalone workflow, research and browser experiments |

The app source boundaries already reflect features and services; this cleanup
keeps their import paths stable. Before moving Python files, read the
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
