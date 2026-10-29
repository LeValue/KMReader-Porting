#!/usr/bin/env bash
set -euo pipefail

adb logcat -c
adb logcat -v threadtime > "${RUNNER_TEMP:-/tmp}/reader-logcat.txt" &
km_log_pid=$!
trap 'kill "$km_log_pid" 2>/dev/null || true' EXIT

adb shell cmd overlay enable --user 0 com.android.internal.display.cutout.emulation.tall
# The driver needs the authenticated VM connection directly. A stalled DDS
# handshake previously left a healthy emulator app paused before any test ran.
timeout --signal=TERM --kill-after=20s 8m flutter drive \
  --driver=test_driver/reader_display_driver.dart \
  --target=integration_test/reader_display_test.dart -d emulator-5554 --no-pub --no-dds
timeout --signal=TERM --kill-after=20s 8m flutter drive \
  --driver=test_driver/native_reader_driver.dart \
  --target=integration_test/epub_reader_test.dart -d emulator-5554 --no-pub --no-dds
