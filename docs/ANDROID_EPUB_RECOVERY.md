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

The native `integration_test/epub_recovery_test.dart` test starts a fresh Android
WebView with saved curl preferences, injects a draw failure, checks actual screen
pixels, navigates again, destroys the reader and reopens its saved CFI. The same
test is included in the existing native Android CI suite. Reader reopen is
tested; Android process death/force-stop and a particular user's EPUB still need
the physical-device checks below.

## Later test on the Mate 20 Pro through MATEBOOK

The manual **Android EPUB recovery diagnostics** workflow builds the diagnostic
APK on GitHub, then runs it through MATEBOOK's `kmreader-laptop` runner. It is
prepared for a later run; adding the workflow does not start it.

1. Keep MATEBOOK signed in with its runner on `Listening for Jobs`.
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
