# Development validation

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
