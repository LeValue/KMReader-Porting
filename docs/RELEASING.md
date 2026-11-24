# Build and release

Use the pinned [development toolchain](DEVELOPMENT.md). Keep
`pubspec.yaml` and `lib/core/app_version.dart` in sync, and increase the build
number for every distributed update. GitHub CI embeds the exact source commit in
both platform builds. Update the notes in [releases](releases/).

Run **Build and test** on the release source. It builds the unsigned Android
APK and portable Windows bundle, including the Kindle worker, matching source
and notices. Use the artifacts from that run.

## Package

1. Create an empty release draft targeting the verified commit. Use
   `v<version>` for a stable release or `v<version>-candidate.<number>` for a
   prerelease.
2. Sign the Android APK locally with the existing distribution key. Keep
   `dev.levalue.kmreader.preview` so Android can update existing installations.
   Verify the APK with `apksigner verify --verbose --print-certs`, compare the
   certificate to `tool/preview-certificate.sha256`, and check alignment with
   Build Tools 36 `zipalign -c -P 16 4`.
3. Stage the signed APK delta from a clean checkout. The universal APK input
   uses the local staging filename `KMReader-<version>-android-universal-preview.apk`.

   ```sh
   GH_REPO=LeValue/KMReader-Porting VERIFIED_RUN=<run-id> DRAFT_TAG=<tag> \
     ANDROID_UNIVERSAL=true python3 tool/stage_draft_deltas.py <signed-apk-dir> \
     --output <delivery-inputs.json>
   ```

4. Dispatch **Build and test** on the same source with `deliver_draft=true`,
   the chosen draft tag, the verified run, `android_universal=true`,
   `apk_deltas=true` and the blob and checksum from the staging output.
   Delivery verifies source, signature, package IDs and artifact checksums.
5. Download the draft APK, Windows ZIP, `kmreader-update.json` and
   `SHA256SUMS.txt`. Check the downloaded hashes, package contents and
   manifest URLs before publishing.

The Android signing key, account data and machine diagnostics belong in
private storage. Publish the draft only after checking the assets. The
portable Windows archive does not have an Authenticode signature.
