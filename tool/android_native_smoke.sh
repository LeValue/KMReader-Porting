#!/usr/bin/env bash
set -euo pipefail

km_binary_directory="$PWD/.dart_tool/native-test-apks"
for km_binary in display reader; do
  if [[ ! -s "$km_binary_directory/$km_binary.apk" ]]; then
    printf '%s\n' "Missing prebuilt native test APK: $km_binary_directory/$km_binary.apk" >&2
    exit 1
  fi
done

adb logcat -c
adb logcat -v threadtime > "${RUNNER_TEMP:-/tmp}/reader-logcat.txt" &
km_log_pid=$!
km_update_fixtures=''
trap 'kill "$km_log_pid" 2>/dev/null || true; if [[ -n "$km_update_fixtures" ]]; then rm -r "$km_update_fixtures"; fi' EXIT

# This disposable emulator verifies actual animation playback. Record and
# normalize the system clock rather than bypassing only its JS media query.
for km_animation_setting in window_animation_scale transition_animation_scale animator_duration_scale; do
  adb -s emulator-5554 shell settings put global "$km_animation_setting" 1.0
  printf '%s: ' "$km_animation_setting"
  adb -s emulator-5554 shell settings get global "$km_animation_setting"
done

adb shell cmd overlay enable --user 0 com.android.internal.display.cutout.emulation.tall

# Test with tiny APKs signed like production (v2/v3), using only disposable
# debug keys on the emulator. Nothing is installed over the running test app.
km_update_fixtures="$(mktemp -d)"
km_sdk="${ANDROID_HOME:?}"
km_tools="$km_sdk/build-tools/36.0.0"
km_test_package=dev.levalue.kmreader.preview
mkdir -p "$km_update_fixtures/assets/flutter_assets/assets/build"
printf '%s\n' '{"source":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"1.0.0","build":999}' > "$km_update_fixtures/assets/flutter_assets/assets/build/source.json"
cat > "$km_update_fixtures/AndroidManifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="dev.levalue.kmreader.preview" android:versionCode="999" android:versionName="1.0.0">
    <application android:label="Synthetic update fixture" android:hasCode="false" />
</manifest>
XML
"$km_tools/aapt2" link -I "$km_sdk/platforms/android-36/android.jar" \
  --min-sdk-version 24 --target-sdk-version 35 \
  --manifest "$km_update_fixtures/AndroidManifest.xml" -o "$km_update_fixtures/raw.apk"
(cd "$km_update_fixtures" && zip -q -0 raw.apk assets/flutter_assets/assets/build/source.json)
"$km_tools/zipalign" 4 "$km_update_fixtures/raw.apk" "$km_update_fixtures/aligned.apk"
for km_flavor in same other; do
  km_key="$km_update_fixtures/$km_flavor.keystore"
  keytool -genkeypair -keystore "$km_key" -storepass android \
    -keypass android -alias fixture -dname "CN=Synthetic $km_flavor fixture" -keyalg RSA -keysize 2048 -validity 2
  "$km_tools/apksigner" sign --ks "$km_key" --ks-key-alias fixture --ks-pass pass:android \
    --key-pass pass:android --v1-signing-enabled false --v2-signing-enabled true \
    --v3-signing-enabled true --v4-signing-enabled false \
    --out "$km_update_fixtures/$km_flavor.apk" "$km_update_fixtures/aligned.apk"
done
# Re-sign this disposable debug app so the test does not depend on the hosted
# runner's Gradle home or the path of its generated debug keystore.
"$km_tools/apksigner" sign --ks "$km_update_fixtures/same.keystore" --ks-key-alias fixture --ks-pass pass:android \
  --key-pass pass:android --v1-signing-enabled false --v2-signing-enabled true \
  --v3-signing-enabled true --v4-signing-enabled false \
  --out "$km_update_fixtures/display.apk" "$km_binary_directory/display.apk"
adb install -r -t "$km_update_fixtures/display.apk"
adb shell run-as "$km_test_package" mkdir -p files/updates
for km_flavor in same other; do
  adb exec-in run-as "$km_test_package" sh -c "'cat > files/updates/$km_flavor.apk'" < "$km_update_fixtures/$km_flavor.apk"
  adb shell run-as "$km_test_package" test -s "files/updates/$km_flavor.apk"
done
adb shell appops set "$km_test_package" REQUEST_INSTALL_PACKAGES allow
# The driver needs the authenticated VM connection directly. A stalled DDS
# handshake previously left a healthy emulator app paused before any test ran.
timeout --signal=TERM --kill-after=20s 8m flutter drive \
  --driver=test_driver/reader_display_driver.dart \
  --target=integration_test/reader_display_test.dart \
  --use-application-binary="$km_update_fixtures/display.apk" -d emulator-5554 --no-pub --no-dds
# Close the system installer without accepting the synthetic APK.
adb shell input keyevent KEYCODE_BACK
adb uninstall "$km_test_package"
timeout --signal=TERM --kill-after=20s 8m flutter drive \
  --driver=test_driver/native_reader_driver.dart \
  --target=integration_test/epub_reader_test.dart \
  --use-application-binary="$km_binary_directory/reader.apk" -d emulator-5554 --no-pub --no-dds
