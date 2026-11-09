# KMReader for Android and Windows

A Flutter implementation of the [KMReader](https://github.com/kmworks/kmreader)
Komga client, based on upstream commit `e2b35f8796cc830fc6e7464e161b2172d8f916e9`.
Browsing, reading, local books, downloads, progress and the Amazon.it Kindle
adapter are implemented. **Full functional and visual parity is not yet
achieved**; see the [porting closure matrix](docs/PARITY.md) and
[settings audit](docs/SETTINGS_AUDIT.md).

## Current version and downloads

The current source is the **1.0.0+33 development candidate**, built on working 0.9.1.
[1.0 changes](docs/releases/v1.0.0.md) include single-page comic gestures/curl,
local-file Send to Kindle, dictionary filtering, responsive Kindle indexing and
separate recently added books/comics on the dashboard.
Build 31 additionally fixes tilted spread curl layers, adds dedicated Kindle send authorization, personal-document management with recovery records, and improves live/offline metadata.
Build 32 fixes real-account Send to Kindle registration (XML/media type) and the relative upload URL lifetime. A generated EPUB was accepted and found in the real catalog; a second process reused credentials without another login or upload. See [live evidence](docs/KINDLE_IMPORT.md).
Build 33 separates cloud-library upload from device-only delivery, retrieves the existing document for editing, and restores verified EPUB reading position, bookmarks and local completion before retiring the old edition. Interruption recovery verifies the journal without repeating submissions. [Management coverage and limits](docs/KINDLE_LIBRARY_MANAGEMENT.md) remain explicit; final build/account checks are recorded in validation.
AI/model/translation extensions and Komga server upload are future work.
See the [readiness record](docs/ROADMAP_1.0.md) and [validation](docs/VALIDATION.md)
for completed checks and target-device acceptance still needed before stable
publication. The existing 0.9.x drafts and all earlier release assets are retained.

[Download signed Android build 33](https://github.com/LeValue/KMReader-Porting/releases/tag/untagged-e4981f585158c367246b) — choose
`android-arm64` for recent phones/tablets, `android-armv7` for 32-bit ARM, or
`android-x64` for x86_64 devices/emulators. Install the APK over **KMReader Preview**
without uninstalling. All three APKs retain the original certificate/package and
versionCode 33. [Delivery and downloaded-byte checks](https://github.com/LeValue/KMReader-Porting/actions/runs/42612973171)
passed; `SHA256SUMS.txt` accompanies the files. This candidate remains a draft
requiring repository write access; stable 1.0 acceptance remains open.

[Download Windows build 33](https://github.com/LeValue/KMReader-Porting/actions/runs/42514188143/artifacts/13631676249).
Extract the complete ZIP into its own directory and run `kmreader.exe`. The existing
app account is reused. [Complete CI](https://github.com/LeValue/KMReader-Porting/actions/runs/42514188143)
passed Android, native Android reader and Windows checks. The downloaded archive
contains 710 files, matches source `e9a7712da95c227a86e5d613409e2c3dda2a7949`, and its SHA256
matches GitHub's artifact digest:
`d21515e59f617573f1d6f5a71db5bbf70b69ae1f855fd7b29c969213a38eb6e7`.
[Previous Windows build 32](https://github.com/LeValue/KMReader-Porting/actions/runs/42483122851/artifacts/13619305441)
remains available.

[Retained Android / Windows candidate build 31](https://github.com/LeValue/KMReader-Porting/releases/tag/untagged-79ed866c31844ad0e3f8).
It remains a draft requiring repository write access. [Complete CI](https://github.com/LeValue/KMReader-Porting/actions/runs/42413142048),
[delivery checks](https://github.com/LeValue/KMReader-Porting/actions/runs/42415254325)
and downloaded hashes passed; all 710 Windows files match the CI bundle.
The [previous build 30](https://github.com/LeValue/KMReader-Porting/releases/tag/untagged-2331050a86fdd8512d55)
is retained. Device/account acceptance and full Kindle state migration remain open.

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
Normal cloud annotation import is one-way. Document replacement separately
restores verified reading position and bookmarks on the new edition; unsupported
annotations preserve the original. See [management limits](docs/KINDLE_LIBRARY_MANAGEMENT.md).

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
