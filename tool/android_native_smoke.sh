#!/usr/bin/env bash
set -euo pipefail

km_binary="$PWD/.dart_tool/native-test-apks/android-native.apk"
if [[ ! -s "$km_binary" ]]; then
  printf '%s\n' "Missing prebuilt native test APK: $km_binary" >&2
  exit 1
fi

adb logcat -c
adb logcat -v threadtime > "${RUNNER_TEMP:-/tmp}/reader-logcat.txt" &
km_log_pid=$!
trap 'kill "$km_log_pid" 2>/dev/null || true' EXIT

# A headless run has no physical input to keep the test activity visible.
adb shell svc power stayon true
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard

# This disposable emulator verifies actual animation playback. Record and
# normalize the system clock rather than bypassing only its JS media query.
for km_animation_setting in window_animation_scale transition_animation_scale animator_duration_scale; do
  adb -s emulator-5554 shell settings put global "$km_animation_setting" 1.0
  printf '%s: ' "$km_animation_setting"
  adb -s emulator-5554 shell settings get global "$km_animation_setting"
done

adb shell cmd overlay enable --user 0 com.android.internal.display.cutout.emulation.tall

# Grant the disposable test app permission to open the system installer.
km_test_package=dev.levalue.kmreader.preview
for km_attempt in 1 2 3; do
  if adb install --no-streaming -r -t "$km_binary"; then break; fi
  if [[ "$km_attempt" == 3 ]]; then exit 1; fi
  adb wait-for-device
  sleep 2
done
adb shell appops set "$km_test_package" REQUEST_INSTALL_PACKAGES allow

# The driver needs the authenticated VM connection directly. A stalled DDS
# handshake previously left a healthy emulator app paused before any test ran.
timeout --signal=TERM --kill-after=20s 10m flutter drive \
  --driver=test_driver/native_reader_driver.dart \
  --target=integration_test/android_native_test.dart \
  --use-application-binary="$km_binary" -d emulator-5554 --no-pub --no-dds
