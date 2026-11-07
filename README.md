# KMReader for Android and Windows

A Flutter implementation of the [KMReader](https://github.com/kmworks/kmreader)
Komga client, based on upstream commit `e2b35f8796cc830fc6e7464e161b2172d8f916e9`.
Browsing, reading, local books, downloads, progress and the Amazon.it Kindle
adapter are implemented. **Full functional and visual parity is not yet
achieved**; see the [parity matrix](docs/PARITY.md) and
[settings audit](docs/SETTINGS_AUDIT.md).

## Current version and downloads

The current source is the **1.0.0+30 candidate**, built on working 0.9.1.
[1.0 changes](docs/releases/v1.0.0.md) include single-page comic gestures/curl,
local-file Send to Kindle, dictionary filtering and responsive Kindle indexing.
AI/model/translation extensions and Komga server upload are future work.
See the [readiness record](docs/ROADMAP_1.0.md) and [validation](docs/VALIDATION.md)
for completed checks and target-device acceptance still needed before stable
publication. The existing 0.9.x drafts and all earlier release assets are retained.

The latest **published** development preview is
[0.8.12](https://github.com/LeValue/KMReader-Porting/releases/tag/v0.8.12-preview.1).
Sign into GitHub with access to this private repository to download it.
Choose one complete APK for your architecture (`android-arm64`, `android-armv7`
or `android-x64`). The optimized app installs as **KMReader Preview** and
retains earlier Preview data when updated with the same signing certificate.
For Windows, extract the complete `windows-x64-preview.zip` and run
`KMReader/kmreader.exe`. The MSVC runtime is bundled; Windows is not Authenticode
signed. Published 0.8.12 does not include the later Kindle integration.

## Development

Use Flutter **3.47.8** / Dart **3.13.7**. Android needs Java 21, SDK/Build Tools 36,
NDK 28.2.13676358 and Python 3.11 for Chaquopy; minimum API is 24. Windows needs
Visual Studio's C++ desktop tools and the separately built Kindle worker.

```sh
flutter pub get --enforce-lockfile
python3 tool/preview_metadata.py
flutter analyze
flutter test
flutter run -d <android-device-id>
```

Start with [development](docs/DEVELOPMENT.md), [testing](docs/TESTING.md) and
[build/sign/distribution](docs/RELEASING.md). The
[documentation index](docs/README.md) distinguishes current procedures from
historical measurements and [archived experiments](archive/README.md).
`ci.yml` owns automatic PR/main builds; device and account diagnostics remain
manual. Dependency versions and local plugin patches are pinned.

## Local books and accounts

Open **Local Books / Libri locali**, then **Import Files**. EPUB, PDF and CBZ/ZIP
files are copied into the app and work offline without an account. Progress
stays on the device; removing an imported copy preserves the original file.
RAR/CBR is not supported yet.

Komga credentials use OS secure storage. Metadata, files, queries and progress
are partitioned by server/account. Progress edits coalesce by book and revision;
new remote conflicts require explicit resolution. TLS verification stays enabled
and redirects do not automatically receive credentials. No production credentials
or demo account are bundled.

Kindle services are managed through Settings / Servers. Kindle conversion uses
shared Python modules and an on-demand native worker; the historical
`tool/kindle_personal/` name does **not** mean those scripts are disposable.
Read the [runtime dependency map](docs/KINDLE_RUNTIME.md) before moving them.
Cloud annotation import is one-way; local bookmarks are not represented as
successfully uploaded to Amazon.

## Repository layout

- `lib/core`, `lib/features`, `lib/ui`: service/persistence logic, app features and
  adaptive controls.
- `android`, `windows`, `assets`, `third_party`: native hosts, shipped resources
  and patched dependencies.
- `test`, `integration_test`, `test_driver`: host, browser and native checks.
- `tool`: [active tools and shared runtimes](tool/README.md).
- `docs`: current guides, release notes and versioned validation evidence.
- `archive`: superseded research and standalone workflow, preserved for reference.

MIT; see [LICENSE](LICENSE). Original artwork/copyright attribution and
`assets/upstream-licenses.json` are retained. Kindle worker GPL notices and
corresponding source accompany native distributions. See
[releasing](docs/RELEASING.md). For an isolated test profile, set
`KMREADER_DATA_DIR` to a writable directory before launching.
