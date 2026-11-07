# Testing

Run from the repository root after the locked dependency setup in
[development](DEVELOPMENT.md). A passing host suite does not establish device
performance, full feature parity, or successful publication.

## Host checks

```sh
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
python3 tool/preview_metadata.py
python3 -m unittest discover -s tool/tests -v
flutter analyze
flutter test
```

The ordinary Flutter suite deliberately skips live Komga, Chromium, real ONNX
and personal Kindle account checks unless their environment variables are set.
Skipped checks must not be reported as executed.

## Shared Kindle runtime and real Chromium

Use Python 3.11 in an isolated environment (Windows: `.venv/Scripts/Activate.ps1`):

```sh
python3.11 -m venv .venv
. .venv/bin/activate
python -m pip install -r tool/kindle_personal/requirements.txt
python -m playwright install chromium
KMREADER_KINDLE_BROWSER_TEST=1 python -m unittest discover -s tool/kindle_personal/tests -v
python -m tool.kindle_personal self-test --output artifacts/kindle-self-test.json --fixtures artifacts/kindle-native-fixtures
KMREADER_KINDLE_FIXTURES=artifacts/kindle-native-fixtures flutter test tool/kindle_personal/tests/native_import_test.dart
KMREADER_BROWSER_TEST=1 flutter test test/epub_browser_test.dart
```

On Linux, install Chromium's system libraries when missing (`python -m playwright
install --with-deps chromium` on a host where package installation is available).
The synthetic tests need no Amazon account. Windows-only DPAPI and real
Chrome/Edge checks execute on Windows; Linux reports their skips explicitly.
`./tool/build_kindle_worker.ps1` runs the Windows Python suite and verifies the
actual frozen executable before packaging. The source packaging test protects
the worker/build/license inputs and excludes private session/book files.

## Real runtimes and backend

```sh
KMREADER_ONNX_TEST=1 LD_LIBRARY_PATH="$PUB_CACHE/hosted/pub.dev/onnxruntime_v2-1.23.2+2/linux" flutter test test/upscaler_test.dart test/bubble_detector_test.dart --no-pub
python3 tool/komga_smoke.py --jar /path/to/komga-1.29.1.jar
```

The ONNX library path above is Linux-specific. The Komga tool verifies the
official JAR digest, starts its own loopback instance, generates credentials and
fixtures, runs the Dart client and removes its own temporary data. It does not
modify an existing server.

## CI and devices

`ci.yml` is the single automatic build/test workflow for PRs and main pushes:

| Job | Required evidence |
|---|---|
| `android` | Format/version, release tool tests, Flutter analyze/tests, Python protocol/browser tests, prepared-book import, shipped reader in Chromium, real ONNX, real Komga, optimized APK |
| `windows` | Shared worker tests/build/self-check/source archive, Flutter host tests, native WebView2 integration, release bundle and isolated startup |
| `android_reader_display` | Real emulator WebView, window insets, reader/comic motion, screenshots and native diagnostics |

All three names are retained because release gates validate them explicitly.
The old standalone prototype workflow is archived; its protocol/import checks
now belong to CI and its duplicate executable recipe uses the shared build script.

`local-windows.yml` dispatches optional Windows/Android diagnostics and the two
reusable Kindle probes. `local-android.yml`, `kindle-personal-probe.yml` and
`kindle-runtime-probe.yml` are specialized reusable workflows, not duplicate
release pipelines. They target registered personal runners only when explicitly
dispatched. Do not run a personal-account probe as part of ordinary PR checks.
Use [local Windows tests](LOCAL_WINDOWS_TESTS.md) for interactive session and
device requirements. Hosted measurements do not prove physical-device FPS.

Record the source commit, exact command, pass/skip/failure counts and device
limits in [validation](VALIDATION.md). Old versioned evidence remains intact.
