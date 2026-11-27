# Build and release

Use the pinned [development toolchain](DEVELOPMENT.md). Keep
`pubspec.yaml` and `lib/core/app_version.dart` in sync, and increase the build
number for every distributed update. GitHub CI embeds the exact source commit in
both platform builds. Update the notes in [releases](releases/).

Run **Build and test** on the release source. It builds the unsigned Android
APK and portable Windows bundle, including the Kindle worker, matching source
and notices. Use the artifacts from that run.

For a build without publication, dispatch **Build and test** with
`final_build=true` after verification. It builds an unsigned APK for each ABI
and the portable Windows bundle from the selected source. Sign the three APKs
locally using the distribution key and the alignment and signature checks below.

## Package

1. Create an empty release draft targeting the verified commit. Use
   `v<version>` for a stable release or `v<version>-candidate.<number>` for a
   prerelease.
2. Prepare the ARM64, ARMv7 and x86_64 APKs from the verified build and sign
   them locally with the existing distribution key. Keep
   `dev.levalue.kmreader.preview` so Android can update existing installations.
   When splitting the verified universal build, retain the common assets and
   only the corresponding native libraries and Chaquopy assets in each APK.
   Run `zipalign -f -P 16 4` on each APK before signing.
   Verify the APK with `apksigner verify --verbose --print-certs`, compare the
   certificate to `tool/preview-certificate.sha256`, and check alignment with
   Build Tools 36 `zipalign -c -P 16 4`.
3. Stage the signed APK deltas from a clean checkout. The staging filenames
   are `KMReader-<version>-android-arm64-preview.apk`,
   `KMReader-<version>-android-armv7-preview.apk` and
   `KMReader-<version>-android-x64-preview.apk`.

   ```sh
   GH_REPO=LeValue/KMReader-Porting VERIFIED_RUN="$run_id" DRAFT_TAG="$draft_tag" \
     python3 tool/stage_draft_deltas.py "$signed_apk_dir" \
     --output delivery-inputs.json
   ```

4. Dispatch **Build and test** on the same source with `deliver_draft=true`,
   the chosen draft tag, the verified run, `apk_deltas=true` and the blobs and
   checksums from the staging output.
   Delivery verifies source, signature, package IDs and artifact checksums.
5. Download the draft APKs, Windows ZIP, `kmreader-update.json` and
   `SHA256SUMS.txt`. Check the downloaded hashes, package contents and
   manifest URLs before publishing.

The Android signing key, account data and machine diagnostics belong in
private storage. Publish the draft only after checking the assets. The
portable Windows archive does not have an Authenticode signature.
