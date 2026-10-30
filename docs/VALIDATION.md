# Development validation

## 0.8.0 candidate — Dashboard boundary and original settings layout

Local analysis is clean. All **267 Flutter checks** pass with Chromium and the
real ONNX runtime enabled; eight Python checks and the pinned upstream inventory
check pass. The separately executed isolated Komga acceptance covers real
CBZ/EPUB/PDF download, caching, offline progress and WebPub synchronization.
The large-font CJK browser regression now also verifies navigation/CFI at 76px.

New checks cover stable Windows-platform Dashboard wheel bounds without shelf
reloads, multi-library POST/GET/offline scopes, old-server and offline next-unread
resolution, global-default changes retaining locators and unrelated book choices,
fresh/upgrade defaults, vertical PDF geometry, calendar/leap/locale ranges,
Italian compact/wide settings and statistics, numeric timeout validation, either
spread page solo without progress changes, PNG export success/cancel/failure and
private temporary-file cleanup. The original native Android export rejection
check now exercises both log and image export. A further native test opens the
EPUB text sheet using the expanded global typography limits (76px, line height
0.5 and letter spacing 1em), covering the old inline-slider assertion. The native
reflowable fixture starts with publisher typography and verifies that adjusting
the text size enables the override while preserving its CFI.

The [reference comparison](IPAD_REFERENCE.md) includes actual Flutter fixture
renders. These do not establish native pixel parity or physical Windows mouse
wheel/GPU performance. Source-matched native/build and package verification are
required before this candidate is published; results are recorded here afterwards.

## 0.7.0 preview — settings audit and verified native controls

Source: `4041b8ca631f4113c6d9f81c8c6fccbc851b4ef8`. All three jobs passed in
[verification 40915646037](https://github.com/LeValue/KMReader-Porting/actions/runs/40915646037).
[Publication 40918815130](https://github.com/LeValue/KMReader-Porting/actions/runs/40918815130)
reused that exact successful source/run and published
[0.7.0](https://github.com/LeValue/KMReader-Porting/releases/tag/v0.7.0-preview.1).

The [settings audit](SETTINGS_AUDIT.md) records 128 persisted keys/structured
fields, 227 control declarations and hashes of 47 files at the pinned upstream
source. It distinguishes implemented controls, native adaptations, internal
state, Apple-only exclusions and partial Core ML model-library management.
Those counts do not describe 128 independent switches or complete parity.

251 Flutter checks pass locally with Chromium and ONNX enabled; static analysis
is clean and eight Python checks pass. The isolated real Komga acceptance also
passes. Thirteen reader/native integration checks pass on **both Android and
Windows**, including actual launcher/window-icon changes, window/status-bar
restoration, all three EPUB layouts, OCR, both portable models, PDFium and native
background transfers. Android additionally passes both API 35 notch/rotation
checks; Windows release compilation and isolated startup pass.

The first native Android run found that percentage scrolling was also handling
paged vertical CJK. The correction limits percentage scrolling to continuous
flow; paged advancement stays with the engine. A Chromium regression simulates
the WebView manager flag, asserts engine delegation and checks CFI advancement.
The original native assertions were retained and pass on the source above.

After publication, all five assets were downloaded again. Sizes and SHA256 match
GitHub asset digests and `SHA256SUMS.txt`; Android bytes match the staged signed
APKs, including source/version/build provenance. Every one of the
**63 Windows files** matches the successful CI artifact.
The Windows bundle contains x64 PE binaries, ELF64 Dart AOT, PDFium, ONNX, both
models, the three icon variants and MSVC runtime; it is not Authenticode signed.

Android retains package `dev.levalue.kmreader.preview`, the previous Preview
certificate and increasing build number 9. Each APK is complete for its ABI.
ZIP alignment is verified at 16 KiB; all nine ELF libraries in each 64-bit APK
also have LOAD alignment of at least 16 KiB. This does not assert 16 KiB native
compatibility for the older ARMv7 libraries. Physical-device frame times, exact
Apple typography/appearance and the explicitly listed parity gaps remain open.

| Download | Bytes | SHA256 |
| --- | ---: | --- |
| ARM64 APK | 77,355,518 | `67542e2b139709e20a3cff5756d3a203a6637e49f4a69586c43f41f16afaed85` |
| ARMv7 APK | 63,656,272 | `925dc940ad66faf95476a03b1b5b8e2ba61c568d71a4df5e7d9c5f2255f36eae` |
| x86_64 APK | 83,591,363 | `e00214cb00bd00ebe3b9ce5150b6686cf31e615cb7a7c87670f9686cf7f94aa6` |
| Windows ZIP | 34,296,829 | `bd6d40a568b84aef5e7c058f989e847ae08044e1db264f7acd3cc047e4c0f3c6` |

Native Android capture from the synthetic vertical-text fixture after changing
the font and advancing; this is not a claim of Apple pixel parity:

![Native vertical EPUB on Android](screenshots/epub-vertical-android-0.7.0.png)

## iPad settings/browse comparison (included in 0.7.0)

The five user-supplied iPad screenshots are now tracked in the
[reference comparison](IPAD_REFERENCE.md), including remaining differences.
The initial comparison passed 232 Dart checks with Chromium and ONNX enabled
and clean static analysis. Six new checks cover live card preferences without catalog requests,
persistence and overlay precedence, decoded-cover geometry and badges, exclusion
of started series from blur, active-tab-only Back handling, 320/1280-pixel layouts
at 150% text size, and search/select-all scope consistency. Existing app flows
exercise the grouped index and retain the sidebar while opening settings subpages.
Synthetic captures use 1280 × 889 and 390 × 844 viewports. These changes are
included in 0.7.0; the source-matched native results are recorded above. Reader,
offline, cache and statistics parity remains subject to the explicit gaps in the
comparison.

## 0.6.1 preview — published with embedded source provenance

Source: `e94e45ef58d74ead79bcdcf91a58cce03ae9b7f4`. All three verification jobs
passed in [workflow 40853768874](https://github.com/LeValue/KMReader-Porting/actions/runs/40853768874).
Publication [40856199505](https://github.com/LeValue/KMReader-Porting/actions/runs/40856199505)
reused that exact successful source/run before publishing
[0.6.1](https://github.com/LeValue/KMReader-Porting/releases/tag/v0.6.1-preview.1).

226 Dart checks pass locally with Chromium and ONNX enabled, alongside static
analysis and six Python release-gate/provenance checks. CI additionally passes
real isolated Komga acceptance, Android release compilation, API 35 notch/rotation,
and Windows release compilation/startup. All eleven reader integration checks
pass on both native platforms, including separate reflowable, fixed-layout and
vertical CJK EPUBs, OCR, bubble detection, Waifu2x, PDFium and background transfers.

Earlier 0.6.1 sources exposed a genuine vertical-text locator regression after
large-font reflow. The browser matrix now covers 390/411/1044-pixel widths, both
flows and 52/60-pixel fonts, including visible anchors and subsequent page turns.
Native Android and Windows confirm the correction on the source above. Android
native test applications are built before starting the emulator to avoid compiler
and emulator resource overlap; assertions were retained. Cleanup now releases
WebView files before removing fixtures, preserving the original failure report.

Each application embeds its source/version/build. Staging rejects a stale APK
before uploading, including a real same-version APK from the earlier source.
The publishing gate verifies both Android and Windows provenance. After publication,
all five assets were downloaded again: their sizes/SHA256 match GitHub asset
digests and the checksum manifest. Android bytes match the staged signed files;
every one of the 57 Windows files matches the exact successful CI artifact.
Windows PE x64 binaries, ELF64 Dart AOT, PDFium, ONNX, both models and MSVC runtime
are present. The Windows bundle is not Authenticode signed.

Android package `dev.levalue.kmreader.preview`, version 0.6.1/code 8 and the retained
certificate permit Preview updates. Each ABI download is a complete application;
APK ZIP alignment is checked at 16 KiB. All nine ELF libraries in each 64-bit
APK also have LOAD segment alignment of at least 16 KiB; this does not assert
16 KiB native compatibility for the older 32-bit ARMv7 libraries. Physical-device frame times and exact
Apple-host visual parity remain unverified. This is a preview, not full parity.

| Download | Bytes | SHA256 |
| --- | ---: | --- |
| ARM64 APK | 76,095,456 | `048092f1023c98c034f268f0f63a321303033373ce7649b42a55007ca1a217ae` |
| ARMv7 APK | 62,297,906 | `325a67eb0c1d8d6be6729142bcfcadd6d00582bf011dd3e37ae5361a474ab32f` |
| x86_64 APK | 82,265,765 | `8a834f81667ca9c9e90f9074924e20306a1e577712bb69700fdd9ff8a7d84ca5` |
| Windows ZIP | 33,606,087 | `b80eac325cb2501b35239eeed6653585f2165c73cd1b13cddd3fae562900d325` |

## 0.6.0 preview — published and downloaded again

Source: `98c42f7ea84d732e7079df795dc26b97caabd0fc`. All three verification jobs passed
in [workflow 40841369727](https://github.com/LeValue/KMReader-Porting/actions/runs/40841369727).
Publication [40844649548](https://github.com/LeValue/KMReader-Porting/actions/runs/40844649548)
reused that exact successful source/run and passed integrity checks before
publishing [0.6.0](https://github.com/LeValue/KMReader-Porting/releases/tag/v0.6.0-preview.1).
The dispatch's duplicate build jobs are skipped because the source-matched
verification run already completed; its source/job gate has three Python tests.

218 Dart tests (Chromium/ONNX enabled locally), static analysis and real isolated
Komga acceptance pass. Native Android and Windows run real EPUB, OCR, original-model
bubble detection/Waifu2x and PDFium raster checks. Windows release/startup passes.
The first native Android attempt passed all nine reader checks but lost its emulator
connection while returning the driver result. The job was rerun on a fresh runner
without changing/skipping tests and then passed. A preceding source's genuine
Android PDF initialization error was corrected with `pdfrxFlutterInitialize`.

All five release assets were downloaded again. Their sizes/SHA256 match GitHub
asset digests and the checksum manifest. All Android bytes match the locally
verified signed APKs; every one of the 55 Windows files matches its successful
CI artifact. The Windows bundle contains x64 PE binaries, a 64-bit ELF Dart AOT
snapshot, PDFium, ONNX, both portable models and MSVC runtime. It is not
Authenticode signed. Physical-device frame times and exact Apple-host visual
parity remain unverified.

All Android variants retain package `dev.levalue.kmreader.preview`, version
0.6.0/code 7, the previous Preview certificate and 16 KiB alignment. Separate,
complete ABI APKs avoid bundling engines for other architectures.

| Download | Bytes | SHA256 |
| --- | ---: | --- |
| ARM64 APK | 76,092,697 | `58aca72e9c7ea441973089636e428c5a78edfc7189a244db920a8b2522fd1e12` |
| ARMv7 APK | 62,278,763 | `b3df9d04f5c55e6e10b23b4fa976107dea1799b04c2c666273e6454a7735a212` |
| x86_64 APK | 82,263,006 | `c86c8bc2ae79d77aab5e4f8dd2023a3ad1b69e475359bd82159687384be510bc` |
| Windows ZIP | 33,602,400 | `651ea0462b55a7428549ab2e07930ac3e7e9dd071bc4d05c8c3952d4dd08a5dc` |


## Unpublished development — native checks complete

Source: `81c3a1dcef7f322358b42af03314738da4f5d82a`. All three build/test jobs passed in
[workflow 40789619987](https://github.com/LeValue/KMReader-Porting/actions/runs/40789619987).
The publishing job was deliberately not requested; the published preview stays 0.5.0.

Android release, 162 automated checks, real Komga acceptance, API 35 notch/rotation,
actual WorkManager/vault downloads, native EPUB CFI/reflow/PixelCopy, OCR and ONNX
passed. Windows native Task Scheduler/vault transfers, EPUB CFI/reflow, OCR, ONNX,
release compilation and isolated startup also passed. The added native display-awake
request/release check passed on both platforms.

This run verifies the disk-space correction after the earlier ordinary Android
runner exhausted its filesystem. The complete runs for `5eb6257` and `434b67d`
also passed. Physical-device frame times and exact Apple-host screenshot parity
remain unmeasured. Later source changes need their own checks.

The subsequent management implementation passes static analysis, 176 automated
tests (Chromium and ONNX enabled), separate real Komga 1.29.1 acceptance and an
Android debug build locally. All three jobs for management source `c1ee4afe094e336fbd240e36018c38fd3f4ee371`
passed in [workflow 40792014992](https://github.com/LeValue/KMReader-Porting/actions/runs/40792014992),
including the Android native export boundary check. This is not a new published release.

The following Komf implementation passes static analysis, 190 automated tests
(Chromium/ONNX enabled), separate real Komga acceptance and an Android debug build
locally. Its connected-server behavior uses controlled HTTP fixtures; stock Komga
verifies the unsupported integration path. Native checks for that later source
will be run separately.

## 0.5.0 preview — verified notch handling and reader/dashboard options

Source: `d95a360f48d3045dc133458f19f3b539715cd19a`. All four jobs passed in
[workflow 40604419297](https://github.com/LeValue/KMReader-Porting/actions/runs/40604419297).
The [published preview](https://github.com/LeValue/KMReader-Porting/releases/tag/v0.5.0-preview.1) contains the verified Android and Windows files.

| Check | Observed result |
| --- | --- |
| Formatting and static analysis | Passed, including integration test/driver sources |
| Automated suites | 96 passed and one live test deliberately skipped, locally and on Linux/Windows CI |
| Real Komga integration | Passed separately locally and in CI, including recently-read/released dashboard filters |
| Native Android display test | Passed on API 35 x86_64 with the OS tall-cutout overlay enabled, including portrait/landscape and exit |
| Android release compilation | Passed locally and in CI |
| Windows release compilation/startup | Passed in CI; welcome window rendered in an isolated profile |
| Published downloads | Downloaded again; SHA256 manifest and GitHub asset digests matched |
| Android integrity | Retained certificate, version 0.5.0/code 6, release AOT/SQLite/PDFium in three ABIs, 16 KiB alignment |
| Windows portable bundle | x64 PE, AOT, native engines and MSVC runtime; every published file matched the CI artifact |

Android: 90,797,216 bytes,
SHA256 `0243474d3cb0ec756982f2ff40e5858379ee3783a8211cc79eefa825720c9efe`.

Windows ZIP: 19,986,126 bytes,
SHA256 `9e4cf92d961d2bc97aa181b428f789e363c7149ec64599cad90877b4ba074aa0`.
The tag points to the exact workflow source above.

The native test executes the real Kotlin MethodChannel/WindowInsets handler in
an Android window. It deliberately clears Flutter's safe padding, asserts a
nonzero OS-reported cutout, checks page and control geometry after rotation,
checks explicit cutout extension without moving controls under it, and checks
the shared document AppBar path. The screenshots below are from this small
display-test harness, not a complete reader acceptance session.

![Android comic display, portrait](screenshots/android-comic-portraitUp-0.5.0.png)
![Android comic display, landscape](screenshots/android-comic-landscapeLeft-0.5.0.png)
![Android document title, portrait](screenshots/android-document-portraitUp-0.5.0.png)
![Android document title, landscape](screenshots/android-document-landscapeLeft-0.5.0.png)
![Native Windows startup](screenshots/windows-startup-0.5.0.png)

Additional unit/widget checks cover actual cropped pixels and safety thresholds,
vertical crop layout, configurable double-tap zoom, leap-year/month-end dashboard
cutoffs and persistent card styles without extra HTTP requests. Existing gesture,
split-page semantic-progress and EPUB/PDF checks remain passing.

The emulator establishes Android platform integration with a simulated cutout;
physical phones, legacy/vendor inset behavior and real frame times still require
target-device acceptance. Full functional/visual parity remains incomplete;
see [PARITY.md](PARITY.md). No pixel comparison against an Apple-host baseline
has been performed.

## 0.4.1 preview — verified comic-reader fixes

Source: `9332ee4bf67fcfa11db645b3941b4c5ae03c15a1`. All three jobs passed in
[workflow 40578135866](https://github.com/LeValue/KMReader-Porting/actions/runs/40578135866).
The [published preview](https://github.com/LeValue/KMReader-Porting/releases/tag/v0.4.1-preview.1) contains the verified Android and Windows files.

| Check | Observed result |
| --- | --- |
| Formatting and static analysis | Passed |
| Full automated suites | 90 passed and one live test deliberately skipped, locally and on Linux/Windows CI |
| Separate real Komga integration | Passed in Android CI |
| Android release compilation | Passed locally and independently in CI, including the native immersive-window handler |
| Windows release compilation/startup | Passed in CI; welcome window rendered in an isolated profile |
| Published downloads | Downloaded again; SHA256 manifest and GitHub asset digests matched |
| Android integrity | Same retained certificate, version 0.4.1/code 5, release AOT/SQLite/PDFium in all three ABIs and 16 KiB alignment |
| Windows portable bundle | x64 PE, AOT, native engines and MSVC runtime; every published file matched the CI artifact |

Android: 90,534,136 bytes,
SHA256 `2fba6a5a42b73b636e0af3ac6e7b0f683b5a41556764af49e4c201a18aa8f3bc`.

Windows ZIP: 19,967,519 bytes,
SHA256 `be231c0b66545f11733e66972653f1f96c43b99e624999950d5046190ae3ddaa`.
The release tag points to the exact workflow source above.

New tests exercise LTR/RTL paging, a second finger arriving after a swipe crosses
the midpoint, rollback without progress writes, remaining-finger pan, zoom reset,
desktop wheel zoom, reuse of the rendered subtree, vertical item recycling,
full viewport geometry with safe controls and Android system-UI ownership.
Existing wide-page pixel and semantic-progress checks continue to pass with the
decode target used for split pages. All three signed AOT snapshots were checked
for the new reader-display channel and differ from 0.4.0.

![Native Windows startup](screenshots/windows-startup-0.4.1.png)

The user reported a successful quick Windows 0.4.0 smoke test. That feedback is
not exhaustive Windows acceptance. Physical Android frame times, touch behavior
and OEM system-bar/cutout behavior still require device validation. The broader
port remains incomplete; see [PARITY.md](PARITY.md).

## 0.4.0 preview — verified release

Source: `f23eaa42ec5713df1ce4f66d03c0124c9817690e`. All three jobs passed in
[workflow 40553979764](https://github.com/LeValue/KMReader-Porting/actions/runs/40553979764).
The [published preview](https://github.com/LeValue/KMReader-Porting/releases/tag/v0.4.0-preview.1) contains the verified Android and Windows files.
The locally signed APK's application/native sources match this commit; subsequent
delivery-tool changes were checked not to modify those sources before dispatch.

| Check | Observed result |
| --- | --- |
| Formatting and static analysis | Passed |
| Full automated suite | 85 passed and one live test deliberately skipped, locally and on both CI platforms |
| Separate real Komga 1.29.1 integration | Passed locally and in Android CI; mixed PNG/TIFF/JPEG2000 comic decoded offline |
| Android release compilation | Passed locally and independently in CI |
| Windows release compilation | Passed in CI |
| Native Windows startup | Window rendered the welcome screen and remained running in an isolated profile |
| Published downloads | Both downloaded again; SHA256 manifest and GitHub REST digests matched |
| Android integrity | Same retained certificate, version 0.4.0/code 4, nondebuggable manifest, AOT/SQLite/PDFium in all three ABIs, 16 KiB alignment |
| Windows portable bundle | x64 PE, AOT, SQLite, PDFium and MSVC runtime; every published file matched the CI artifact |

Android: package `dev.levalue.kmreader.preview`, 90,533,968 bytes,
SHA256 `b3b06a59f52eebfb457aaa0ecdb5c69607c5b9df1b06e1180c520599b2fc9bdf`.

Windows ZIP: 19,961,165 bytes,
SHA256 `8064f7b9e6da0c36064874e06cf30eec225e84c612d1508d3663414907aefb5e`.
The release tag points to the exact workflow source above.

Native PDFium widget tests cover mixed-size spreads, complete spread fitting,
cached series RTL, layout/theme changes without progress writes, normal/incognito
navigation, AES-128 wrong-password retry, actual text search and result/page
retention after viewport changes. EPUB tests navigate supplementary notes outside
the linear spine, return without changing canonical progress, and preserve the
scroll fraction across font and font-size changes. Download fixtures use a real
generated PNG rather than arbitrary non-image bytes.

![Native Windows startup](screenshots/windows-startup-0.4.png)

These checks do not establish complete functional/visual parity or phone frame
times. Physical Android and manual Windows interaction, vault/background behavior,
AI/OCR and the other gaps in [PARITY.md](PARITY.md) still require work.

## 0.3.0 preview — verified release

Source: `77a5786fb19c173e7925b6a64e5d424ffb843eb3`.
All three jobs passed in [workflow 40516070398](https://github.com/LeValue/KMReader-Porting/actions/runs/40516070398).
The [published preview](https://github.com/LeValue/KMReader-Porting/releases/tag/v0.3.0-preview.1)
contains Android and Windows artifacts.

| Check | Observed result |
| --- | --- |
| Static analysis and formatting | Passed |
| Full automated suites | 73 passed and one live test intentionally skipped, on both Linux and Windows |
| Separate real Komga 1.29.1 integration | Passed in the Android CI job |
| Android release compilation | Passed locally and independently in CI |
| Windows release compilation | Passed in CI |
| Native Windows startup | Window created, remained running and rendered the welcome screen in an isolated profile |
| Windows bundle | x64 PE, AOT library, SQLite, PDFium and MSVC runtime verified |
| Published download verification | Both files downloaded again; manifest and GitHub REST asset digests matched |
| Android package integrity | Retained certificate, nondebuggable manifest, AOT/SQLite/PDFium in three ABIs and 16 KiB alignment verified |

Android: package `dev.levalue.kmreader.preview`, version `0.3.0` (code `3`),
90,320,204 bytes, SHA256
`496ab8d6c83cff9e390a11771d28c70e9374c24390640fce8ce79eb49d99b3e7`.

Windows ZIP: 19,924,818 bytes, SHA256
`be669e3de514c4830c60770a77e467f3a68442a697951f7c7e2cb951ca96ced2`.
Every file in the published Windows ZIP matched the exact CI bundle that passed
native startup. The release tag points to the verified source commit above.

The cache regression freezes the clock so an explicitly requested refresh cannot
be hidden by equal Windows timestamps. It also asserts that the fetched replacement
is reused without a third request. No timeout or assertion was removed to pass it.

The real-server test covers metadata edits/locks, nested filters, read-list reorder
and read-status filters, statistics fallback, collection CRUD, library creation,
editing/removal, authentication, reader/download and progress checks. Extended kmrs
smart-list/statistics endpoints use contract fixtures: the available real server is
stock Komga, whose 404 fallback was checked. No physical Android device was used.
Windows startup is not acceptance of every native reader/vault interaction. Full
visual, AI/OCR and OS-integration parity is not established.

![Native Windows startup](screenshots/windows-startup-0.3.png)

## Earlier validation snapshots

Validated in the prepared Linux cloud workspace with Flutter 3.47.8, Dart
3.13.7, Java 21 and Android SDK 36. Upstream reference remained unchanged at
`e2b35f8796cc830fc6e7464e161b2172d8f916e9`.

| Check | Observed result |
| --- | --- |
| Dart formatting | All 28 Dart files formatted |
| `flutter analyze` | No issues |
| `flutter test --reporter expanded` | 27 passed; live Komga test deliberately skipped |
| `python3 tool/komga_smoke.py --jar …/komga-1.29.1.jar` | Separate real-server integration test passed |
| `flutter build apk --debug` | Universal Android development APK built |
| Android `apksigner verify --verbose` | Verified APK Signature Scheme v2, one signer |
| Android `zipalign -c -P 16 4` | Passed |
| APK contents | Flutter, PDFium and SQLite native libraries present for all three ABIs |
| Windows release build and automated tests | Passed on a GitHub Windows runner; see remote evidence below |
| Windows app interaction | Not run |
| Android device/emulator execution | Not run; no device or accelerated emulator available |

The real-server test uses a disposable Komga 1.29.1 with synthetic books. It
covers password/API-key authentication and revocation, search, ordered reading
lists and continuation, CBZ/EPUB/PDF downloads, offline comic pages and progress,
and canonical Readium progression synchronization. It never changes the
persistent development server.

The EPUB widget tests exercise actual taps in chapter hyperlinks and the nested
index, including escaped paths/fragments and asynchronously parsed chapters.
They verify that the requested heading is visible, that font changes preserve
the scroll fraction without sending new progress, that initial restoration
finishes before navigation is accepted, and that incognito navigation creates
neither persisted positions nor outgoing progress. Parser tests cover EPUB 3
namespace aliases/accessibility roles, EPUB 2 NCX, invalid links and spine fallback.

## Android artifact

- Path: `build/app/outputs/flutter-apk/app-debug.apk`
- Package: `dev.levalue.kmreader`
- Version: `0.1.0` (code `1`)
- Minimum SDK: 24; target/compile SDK: 36
- ABIs: `armeabi-v7a`, `arm64-v8a`, `x86_64`
- Size: 235,932,312 bytes
- SHA256: `476ec84a05b6e41de688e29c45e64e8cfc9179abe298c38b604769704e7449d2`

This is a development APK signed with a local debug key. Release signing is a
separate build configuration. APK signature/alignment checks establish package
integrity, not target-device behavior.

## Remaining acceptance work

The [parity matrix](PARITY.md) tracks missing functionality. Exact visual
matching has not been established against an Apple-host screenshot baseline.
Secure storage on both target systems, real-device reader
behavior, accessibility, background work and performance still require target
testing. This report records local checks; subsequent remote build results must
be verified separately in GitHub Actions.

## Remote Windows evidence

The Windows job for source commit
`3e5a7e03a81636e3da304b9723ae6abf9a3972eb` successfully completed dependency
resolution, static analysis, the automated test suite, `flutter build windows
--release`, and artifact upload:

https://github.com/LeValue/KMReader-Porting/actions/runs/40469392697/job/122072544496

The downloaded `windows` artifact (ID `12717309125`, 19,170,395 bytes) was inspected
as a ZIP. It includes a PE `kmreader.exe`, `flutter_windows.dll`, PDFium and SQLite
DLLs, and the compiled Dart AOT asset. This establishes compilation and bundle
contents, not manual interaction with the installed app. The Android setup job
in that initial run failed on the retired SDK `tools` package; the workflow now
requests `platform-tools` explicitly.

## Published Android preview

The corrected workflow completed its Android, Windows, and preview-publishing
jobs successfully:

https://github.com/LeValue/KMReader-Porting/actions/runs/40469954248

The Android job passed formatting, analysis, the automated suite, the separate
real Komga integration test, and universal debug APK compilation. The publishing
job uploaded both assets, compared their sizes and SHA256 digests with GitHub's
metadata, and then published the prerelease. The actual published APK was
downloaded back to the cloud workspace and independently passed SHA256,
`apksigner` v2 signature, and 16 KiB ZIP alignment checks. Flutter, PDFium and
SQLite libraries were confirmed for ARMv7, ARM64 and x86_64.

- Release: https://github.com/LeValue/KMReader-Porting/releases/tag/v0.1.0-dev.1
- Source: `39988b1c7e279b0c9c76038bd3b5ffa6211e431b`
- Asset: `KMReader-0.1.0-android-debug.apk`
- Size: 198,405,673 bytes
- SHA256: `657d84ddbd74d4d6f3bff0ae8c6ffd0c1f5bf978e4f36714d374538e41227303`

This is a separate CI build with the runner's development signing key; its
checksum differs from the earlier local APK documented above. GitHub login with
repository access is required to download from this private repository. Target
device interaction and complete functional/visual parity remain unverified.

## Optimized 0.2.0 preview

Local validation of the cache/UI iteration passed 38 tests (one separate live
test skipped in that suite), static analysis and the separate real Komga test.
See [PERFORMANCE.md](PERFORMANCE.md) for measured cache behavior and coverage.
The signed universal APK was built in release mode with AOT libraries for all
three ABIs, no debug kernel and no `application-debuggable` flag. Its manifest
launches `dev.levalue.kmreader.MainActivity` under the separate preview package.

- Package: `dev.levalue.kmreader.preview`, label `KMReader Preview`
- Version: `0.2.0` (code `2`), Android API 24 minimum / 36 target
- Local artifact: `build/app/outputs/flutter-apk/app-release.apk`
- Size: 88,332,640 bytes
- SHA256: `174194343bf8a974d0da4cb715b3a6de4a626974eee21043b388d54e344e49b9`
- Certificate: public SHA256 in `tool/preview-certificate.sha256`

This build installs alongside 0.1.0; it does not overwrite that app's storage.
The user reported successful real-server connection and comic/ebook reading
with 0.1.0, while also reporting UI lag. This optimized build still requires
fresh performance and behavior acceptance on the user's device.

The complete CI workflow for source
`fc5b32be6c613eb936696134cb598b40037f950b` succeeded for Android, Windows, and
preview publication:

https://github.com/LeValue/KMReader-Porting/actions/runs/40482167262

The exact signed APK was published at
https://github.com/LeValue/KMReader-Porting/releases/tag/v0.2.0-preview.1,
downloaded back through GitHub, and independently checked against its SHA256,
retained certificate, non-debuggable manifest, AOT/native libraries for all
three ABIs, APK signature and 16 KiB ZIP alignment. The downloaded file matches
the local artifact listed above byte for byte.

## Continuous EPUB development

The continuous-chapter increment passes static analysis, 190 automated checks
(Chromium/ONNX enabled) and an Android debug build locally. After the final
input-listener cleanup the focused Chromium/session/host checks pass again.
The browser test verifies both chapter boundaries, exact-section CFI resume on
a cold start, stable progress through repeated flow/font changes, and teardown
without browser errors. Native flow-switch checks have been added for the next CI
run; physical scrolling smoothness is not established by this browser fixture.

## Account password development

The password increment passes static analysis, 200 automated tests with Chromium
and ONNX enabled, Android debug compilation and separate real Komga 1.29.1
acceptance. The live fixture changes/restores its own generated password through
the actual controller, secure-store interface and reconnection flow. Controlled
fault tests cover a lost response, denied operation, offline guard, failed vault
write, account removal and server switch. Form tests validate confirmation and
prevent closing an in-flight mutation. Native CI for this later source is pending.

## Authentication activity development

Static analysis, 202 automated tests (Chromium/ONNX enabled), Android debug
compilation and separate real Komga acceptance pass locally. Two enlarged-text
widget variants verify pagination, expanded details, refresh rejection/retry and
offline reuse without HTTP requests. Stock Komga returns the real current-user
authentication activity page. Native verification for this later source is pending.

All three jobs for Komf source `969927feed1bbcac1a2b0f7c7626664879a3590f` passed in
[workflow 40795789235](https://github.com/LeValue/KMReader-Porting/actions/runs/40795789235).
The continuous EPUB source `797c269694ea9edd213ed8b1ed4cdcbd420e10c4` has passed both
Android jobs; its Windows release job is still running at this checkpoint.

## PDF continuation development

All 202 automated checks (including actual PDFium, Chromium and ONNX), static
analysis and Android debug compilation pass after forwarding PDF continuation
through DocumentReader. The actual viewer tests cover normal/incognito progress,
completion and duplicate next-book taps. The existing native display/OCR/EPUB
suites will run on the new source in CI.

All three jobs for continuous EPUB source `797c269694ea9edd213ed8b1ed4cdcbd420e10c4`
passed in [workflow 40797242432](https://github.com/LeValue/KMReader-Porting/actions/runs/40797242432),
including native flow changes and navigation afterwards on Android WebView and
Windows WebView2, both release builds and Windows startup.

## OCR lifecycle and native-driver startup

Static analysis, all 204 automated tests (Chromium/ONNX enabled), and Android
debug compilation pass with repository-owned OCR lifetime and cache cleanup.
Account removal during an active native reply and concurrent cache replacement
have dedicated regressions.

All three jobs passed for password source `e57f20dc935887527f0db8677496080b39b606cd`
in [workflow 40798165296](https://github.com/LeValue/KMReader-Porting/actions/runs/40798165296).
Authentication-activity source `0586c6c` passed Android release and Windows,
but its native Android job timed out before any test ran: logcat shows a healthy
app VM waiting while FlutterDriver could not connect through DDS. A later
`717387c` native Android job passed with the same display suite. The Android
smoke script now selects the supported `--no-dds` direct VM connection, retaining
the existing per-drive timeout and all test assertions. Verification of that
script change is pending its new CI run. Failure logcat is retained locally
under ignored `artifacts/verification-post-0.5/auth-history-native-failure/`.

## Portable bubble detection development

All three jobs for OCR lifecycle/direct-driver source
`dffae2cf7d9c6687e37ed63781663e3ecbf959d5` passed in
[workflow 40801945481](https://github.com/LeValue/KMReader-Porting/actions/runs/40801945481),
including Android native integration with `--no-dds`.

The later portable bubble detector passes static analysis, all 211 automated
tests with Chromium/ONNX enabled, and Android debug compilation locally.
The actual ONNX worker and source-network probe comparison pass; widget tests
cover opt-in, pending work, incognito and native OCR fallback at 320/1280 pixels
with enlarged text. Native Android/Windows model execution is added to CI and
is pending for this source. No new installable preview has been published.

## Local PDF comic/DIVINA reader development

Static analysis, all 218 automated tests (Chromium/ONNX enabled) and Android
debug compilation pass locally. Actual PDFium tests verify chosen output size,
correct color/orientation of mixed-size pages, request coalescing/cache refresh,
closure, encrypted password retry, offline resume and normal/incognito completion
and next-book callbacks. Settings fit 320/1280-pixel layouts. A portable mixed-size
PDF fixture also checks actual Android/Windows PDFium raster output in native CI;
that new source has not yet completed native CI. No new release is published.

## EPUB layout correction development after 0.6.0

All 222 automated checks (Chromium/ONNX enabled), static analysis and Android
debug compilation pass locally. Dedicated real-browser cases cover paged/scrolled
fixed layouts and vertical CJK, authored text/color/position preservation,
publisher spreads, scroll input, visible CFI/fragment destinations, visible
anchors after font changes and completion bounds. Native suites now include
separate reflowable/fixed/vertical publications with distinct Android PixelCopy
screenshots. That later source is awaiting native CI; 0.6.0 downloads remain the
verified published checkpoint above. Release 0.6.1/code 8 is being prepared.

The 0.6.1 native checks exposed a genuine vertical-text reflow defect on Windows
(and Android once its driver connection remained stable): large-font page turns
could retain a paragraph-start locator. A desktop/browser reproducer now covers
390/411/1044-pixel widths, 52/60-pixel text, visible saved anchors and subsequent
CFI changes in both flows. Physical-height locator alignment and visible-character
caret mapping pass all 226 local Dart checks (Chromium/ONNX enabled), plus static
analysis. Native cleanup now unmounts the WebView even when an assertion fails,
so temporary-file locks cannot hide the original failure.

Android CI precompiles both test APKs, stops Gradle and uses the supported
prebuilt-binary driver mode. This removes compiler/emulator overlap without
changing assertions or the eight-minute drive bound. That revised execution
reached the CJK assertion without a transport disconnect; no host OOM cause is
claimed. Diagnostic filtering now uses grep on runners without ripgrep.
Embedded build provenance and six Python release-gate checks reject missing,
malformed or stale source/version records. Fresh native CI is required before
publishing the updated 0.6.1 binaries.
