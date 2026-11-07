# Android EPUB recovery regression

On the physical Huawei Mate 20 Pro (LYA-L09, Android 10/API 29, WebView 156),
texture composition displayed a blank book in the controlled-frame native test
despite valid DOM pagination and CFIs. It logged offscreen buffer errors with
the default renderer. Hardware-accelerated hybrid composition restored visible
text. The candidate selects that mode automatically on Huawei Android 10; other
Android configurations retain the existing texture path. This compatibility
scope passed on LYA-L09. A repeat with normal live frame scheduling is still
required to exclude a texture-consumer scheduling effect in this test harness.
Earlier requests for Skia lost their launcher parameters; those runs cannot be
used to compare Flutter rendering backends. The launcher now preserves extras
and the test verifies that requested flags were actually applied.

The candidate also fixes an animation frame exception that left its fullscreen GPU
snapshot above the live publication. GPU compilation and page capture now have
deadlines; context loss retires the animation and its GPU resources. Subsequent
curl commands use direct navigation in that WebView after a graphics failure.
A WebView recreated after a renderer-process exit restores the book with motion
disabled for that reader session, without changing saved preferences.

`tool/epub_recovery_smoke.py` reproduces the stuck overlay on 0.8.12 and checks
fault recovery, delivered text pixels and saved-CFI reload in Chromium. It also
injects pointer draw errors, context loss, unfinished compilation/capture,
cancellation, suspended animation callbacks and backgrounding. This is not
evidence that a particular Android GPU/driver works.

Slide/cover checks also reject cancelled compositor animations and stalled View
Transition preparation, and verify cleanup when the final style update throws.
Renderer-recovery configuration is checked against all three motion styles and
idle warming.

The native `integration_test/epub_recovery_test.dart` test starts a fresh Android
WebView with saved curl preferences, opens/closes text settings, completes a
normal GPU curl, injects a draw failure, checks actual screen pixels, navigates
again, destroys the reader, reopens its saved CFI and exercises real WebGL
context loss. The same test is included in the existing native Android CI suite. Reader reopen is
tested; Android process death/force-stop and a particular user's EPUB still need
the physical-device checks below.

## Test on the Mate 20 Pro through a Windows runner

The manual **Android EPUB recovery diagnostics** workflow builds the diagnostic
APK on GitHub, then runs it through the selected Windows runner. The fixed PC
can use `kmreader-android-desktop`; MATEBOOK uses `kmreader-laptop`. If custom
label routing does not assign the fixed PC, select `self-hosted` and set
`expected_runner: GAETANO-FISSO`. The first job step checks that exact name
before setup or device access. The candidate history was merged into `main`; the retired `fix/android-epub-recovery` branch is recorded in [the branch cleanup inventory](inventory/branch-cleanup-2026-11-07.json).
Until the new workflow reaches the default branch, start the existing **Local
Windows diagnostics** workflow on that candidate branch with mode
`android-epub-recovery` and the chosen `runner_label`. It calls the Android
workflow from the same commit and skips the Windows tests.

1. Keep the selected Windows PC signed in with its runner on `Listening for Jobs`.
2. Connect the Mate 20 Pro by USB, enable USB debugging, authorize this PC and
   leave the phone unlocked. Disconnect other Android devices/emulators.
3. Run **Local Windows diagnostics** on the candidate branch with mode
   `android-epub-recovery`, the selected label/name and `android_composition: auto`.
   The first run installs the pinned Flutter driver, Java and Android driver SDK
   in runner caches; no local app compilation is required. The SDK bootstrap
   supports Windows PowerShell 5.
4. Open `android-epub-recovery-results` for the log, model/Android version,
   APK hash, `report.json` and PNGs of the diagnostic app at each reading phase.
   `prebuilt_run` reuses a successful build only after comparing app/test source.
   The APK is retained in the runner cache for USB/launcher-only retries.

The ARM64 APK is a debug functional probe named **KMReader EPUB Test**, with
package `dev.levalue.kmreader.epubdiagnostic`. It uses generated text and a
temporary database. It does not access Komga credentials or downloaded books.
Only this diagnostic package is reset and removed after testing. Huawei may
refuse global deletion after already removing it from the primary user;
`cleanup.txt` records removal and any remaining-package warning separately from
the reader-test result. Debug timings
are not release-performance or display-FPS measurements.

After the automated test passes, test a separately built candidate in the actual
app with the downloaded *Alice*: cold open with saved curl, several forward/back
turns and a chapter crossing, cancel a drag, open/close text settings, switch
away during a turn and return, then close/reopen the book and force-stop/relaunch
the app. Text must remain visible, input must recover and the reading position
must be retained. Repeat with slide and vertical scrolling. Record failures
before changing reader preferences or clearing data; a data reset would hide a
saved-position regression. The generated-fixture phone regression has run;
these real-book/process-restart checks and release-performance measurements
remain separate work.

## Recovery candidate validation (2026-11-03)

- The new draw-failure regression failed on the unmodified reader: the opaque
  canvas remained attached after a thrown animation-frame update.
- Before the subsequent pipeline audit, all 332 host tests passed with browser and ONNX checks enabled;
  one live-Komga test was skipped in that local run. All 21 browser tests passed.
  The additional slide/cover/recovery-configuration fault cases also passed.
- `flutter analyze --no-pub`, formatting and the eight Python tool tests passed.
- The physical [automatic-selection run](https://github.com/LeValue/KMReader-Porting/actions/runs/41690247315)
  passed cold opening, text-settings close, GPU-fault recovery, subsequent
  navigation, native-reader reopen, a complete normal curl and context loss. Each screenshot contained
  45,131–50,503 dark glyph pixels in its center. `compositionOverride` was false
  and `hybrid` was true: the normal runtime policy selected the working path.
- The [forced-hybrid comparison](https://github.com/LeValue/KMReader-Porting/actions/runs/41677523211)
  passed the reader checks. Its job failed only on vendor package cleanup;
  later launcher code separates that outcome and checks primary-user removal.
- Saved-page PNGs before and after native-reader reopen are identical. Text-area
  pixels change on each actual page advance, so a stale viewport is not counted
  as successful navigation.
- The valid [forced-texture comparison](https://github.com/LeValue/KMReader-Porting/actions/runs/41691470387)
  used the same APK with a verified texture override. Its cold-open screenshot
  contained zero glyph pixels despite valid iframe height. Both this and the
  successful automatic run used controlled test frame scheduling.
- [Machine-readable comparison](benchmarks/epub-android-mate20-recovery.json)
  records the actual launch modes and their test-harness limits.

The standalone diagnostic APK is separate from the installed reader. The
published 0.8.12 APK remains unchanged. These physical runs tested runtime
`1340ddc`; the subsequent [0.8.13 pipeline audit](EPUB_RENDERING_AUDIT.md)
has separate validation and must not be presented as measured on this phone.
Debug callback intervals are not physical display FPS or a release-performance
measurement. Real-book testing with the downloaded Alice remains pending.
