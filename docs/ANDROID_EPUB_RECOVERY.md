# Android EPUB recovery regression

The candidate fixes an animation frame exception that left its fullscreen GPU
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
WebView with saved curl preferences, injects a draw failure, checks actual screen
pixels, navigates again, destroys the reader, reopens its saved CFI and exercises
real WebGL context loss. The same
test is included in the existing native Android CI suite. Reader reopen is
tested; Android process death/force-stop and a particular user's EPUB still need
the physical-device checks below.

## Test on the Mate 20 Pro through a Windows runner

The manual **Android EPUB recovery diagnostics** workflow builds the diagnostic
APK on GitHub, then runs it through the selected Windows runner. The fixed PC
uses the additional label `kmreader-android-desktop`; MATEBOOK uses
`kmreader-laptop`. The candidate currently lives on `fix/android-epub-recovery`.
Until the new workflow reaches the default branch, start the existing **Local
Windows diagnostics** workflow on that candidate branch with mode
`android-epub-recovery` and the chosen `runner_label`. It calls the Android
workflow from the same commit and skips the Windows tests.

1. Keep the selected Windows PC signed in with its runner on `Listening for Jobs`.
2. Connect the Mate 20 Pro by USB, enable USB debugging, authorize this PC and
   leave the phone unlocked. Disconnect other Android devices/emulators.
3. Run `.github/workflows/local-android.yml` on the candidate commit. The first
   run installs the pinned Flutter driver, Java and Android platform tools in
   runner caches; no local app compilation is required.
4. Open the `android-epub-recovery-results` artifact for the pass/fail log,
   model/Android version and tested APK hash.

The ARM64 APK is a debug functional probe named **KMReader EPUB Test**, with
package `dev.levalue.kmreader.epubdiagnostic`. It uses generated text and a
temporary database. It does not access Komga credentials or downloaded books.
Only this diagnostic package is reset and removed after testing. Debug timings
are not release-performance or display-FPS measurements.

After the automated test passes, test a separately built candidate in the actual
app with the downloaded *Alice*: cold open with saved curl, several forward/back
turns and a chapter crossing, cancel a drag, open/close text settings, switch
away during a turn and return, then close/reopen the book and force-stop/relaunch
the app. Text must remain visible, input must recover and the reading position
must be retained. Repeat with slide and vertical scrolling. Record failures
before changing reader preferences or clearing data; a data reset would hide a
saved-position regression. No phone test or release performance claim is made
until these checks have actually run.

## Candidate validation (2026-11-03)

- The new draw-failure regression failed on the unmodified reader: the opaque
  canvas remained attached after a thrown animation-frame update.
- After the fix, all 332 host tests passed with browser and ONNX checks enabled;
  one live-Komga test was skipped in that local run. All 21 browser tests passed.
  The additional slide/cover/recovery-configuration fault cases also passed.
- `flutter analyze --no-pub`, formatting and the eight Python tool tests passed.
- Native CI run [41640810909](https://github.com/LeValue/KMReader-Porting/actions/runs/41640810909)
  passed all 23 Android reader tests, including GPU-fault/context-loss recovery
  and saved-CFI reader reopen, plus the two display/insets tests. Its native
  Windows WebView2 test step also passed. These tests use the same application
  and native-test source as the prepared candidate.
- The separate Android release CI job stopped on an interrupted PDF transfer in
  the live-Komga fixture. Repeating that real-server integration test locally
  passed. The overall CI run must not be described as fully green on this
  evidence.
- The dedicated debug diagnostic APK compiled locally. Its manifest package is
  `dev.levalue.kmreader.epubdiagnostic`, debuggable is true, and its bundled
  `reader.js` exactly matches the candidate. Provenance identifies runtime commit
  `4dca7711ad87720e8e13ea420f53fd7fdce70c92`; SHA256 is
  `d44f2791864500ab0864605d3f507aef9b8f91a6330a7283fc70ef3a5da67336`.

This APK is a diagnostic probe, not a new public app release. The published
0.8.12 release remains unchanged. Physical Mate 20 Pro testing is pending.
