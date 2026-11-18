#!/usr/bin/env bash
set -euo pipefail

# Test with tiny APKs signed like production (v2/v3), using only disposable
# debug keys on the emulator. Nothing is installed over the running test app.
km_update_fixtures="${1:?fixture directory required}"
km_sdk="${ANDROID_HOME:?}"
km_tools="$km_sdk/build-tools/36.0.0"
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
