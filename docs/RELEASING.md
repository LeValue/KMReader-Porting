# Build, sign and distribute verified previews

The next publication target is **1.0.0**; keep existing 0.9.x candidates in draft
until the [1.0 readiness work](ROADMAP_1.0.md) is complete.

Current source: **0.9.1+29**. Its existing candidate release remains a draft;
this procedure does not publish it automatically. See [development](DEVELOPMENT.md)
for prerequisites and [testing](TESTING.md) for the required checks.

For a local diagnostic build, use `flutter build apk --debug`. It uses the debug
key and cannot update the signed Preview package. For Windows release builds,
run `./tool/build_kindle_worker.ps1`, then `flutter build windows --release`; copy
`artifacts/kindle-dist/KMReader-Kindle` to `build/windows/x64/runner/Release/kindle`,
the matching `artifacts/kindle-delivery/*-source.zip` beside the executable, and
`assets/kindle/NOTICE.md` as `Kindle-NOTICE.md`. Distribute the entire Release
directory, including native DLLs, data and the MSVC runtime. CI does all of this.

## Retain the Android signing identity

Use the existing ignored `android/key.properties` and its existing private
keystore. Do not generate a replacement key for an update. The properties are
`storeFile`, `storePassword`, `keyAlias`, `keyPassword`; keep their values out of
Git, PRs, logs and CI. Without this file release output is unsigned; the debug
key is never substituted. The expected public certificate SHA256 is in
`tool/preview-certificate.sha256`. Preserve the Preview package ID
`dev.levalue.kmreader.preview`, the certificate and the increasing version code
to retain upgrade/data compatibility. The diagnostic app has a separate ID.

## New distributed update

The version in `pubspec.yaml` and `lib/core/app_version.dart` must agree.
Increment the Android build number for every published update and add notes at
`docs/releases/v<version>-preview.1.md`. `tool/preview_metadata.py` checks these
values before CI builds or publication.

Commit the source, then run `python3 tool/prepare_build_metadata.py` to generate
the embedded source/version record. CI does this for both platforms too.
Build Android with the retained, private signing configuration. The key is not
uploaded to CI. Produce complete APKs for all three architectures:

```sh
# Chaquopy has explicit ABI filters: build one complete APK at a time.
# Save each output before building the next architecture.
mkdir -p artifacts/signed-preview
for target in android-arm64 android-arm android-x64; do
  env 'ORG_GRADLE_PROJECT_force-version-code-ignoring-abi=true' \
    ORG_GRADLE_PROJECT_kmreaderPreview=true \
    flutter build apk --release --target-platform "$target"
  cp build/app/outputs/flutter-apk/app-release.apk "artifacts/signed-preview/$target.apk"
done
```

The explicit version-code flag keeps each architecture on the same increasing
build number, preserving upgrade compatibility with the older universal APK.
Do not use `--split-per-abi`: AGP splits conflict with Chaquopy ABI filters.
Check
the actual `aapt2 dump badging` output with `tool/preview_metadata.py --apk-badging
<file> --abi <abi>`.

Verify each APK's retained certificate, package ID, version, non-debuggable mode
and 16 KiB ZIP alignment. Stage each complete APK with `tool/stage_preview.py`;
retain its returned source commit, Git blob and SHA256. Staging requires a clean
checkout and embedded provenance matching HEAD; the publisher checks that record
again against the source-matched CI revision. The tool rejects a payload over its
request budget. Do not commit APKs or split one APK into upload fragments.

Create an empty draft for the versioned tag, targeting the exact source commit.
Run the ordinary build/test workflow on that source and wait for all three jobs
to pass: Android release/host/backend checks, native Android integration, and
Windows host/native/release/startup checks. A transport failure after tests must
still be resolved; a partially successful job does not satisfy the gate.

Dispatch `ci.yml` on `main` with `publish_preview=true`, the three staged blob/hash
pairs, and optionally `verified_run` for that completed CI run. When reusing a
run, duplicate build jobs are skipped and `tool/verify_preview_ci.py` requires
the exact commit, repository, main branch, expected workflow, successful run and
all required job names. Artifacts come from that verified run. Without reuse,
all three jobs execute in the dispatch itself.

The publisher repeats APK integrity checks, packages the matching Windows
artifact with its native engines and MSVC runtime, verifies uploaded asset
digests, and only then publishes the draft. It refuses an existing release or
a nonempty draft. Existing published assets are preserved.

After publication, download every asset, verify `SHA256SUMS.txt` and GitHub's
asset digests, compare the Android files with the locally verified APKs and all
Windows bundle files with the successful CI artifact. Update README download
links and `docs/VALIDATION.md` with the exact source, runs and observed limits.
A development preview must not be presented as verified full upstream parity.

For review builds before merging, `ci.yml` also supports `deliver_draft=true`,
an existing empty `v<version>-epub-candidate.<number>` draft, `verified_run`, and
the three staged APK blob/hash pairs. This skips compilation and public
publication. `tool/deliver_draft.py` requires successful Android/Windows/native
CI, unchanged application/runtime sources, matching APK provenance, signatures,
architecture, alignment and exact bytes. It packages the matching Windows CI
artifact and verifies GitHub asset digests. The existing draft must target the
verified commit and remains unpublished. Delivery-only tooling may be added
after that verified runtime commit; runtime changes require fresh complete CI.


## Preserve existing deliverables

Never overwrite a nonempty draft, mutate a published asset, move an existing tag
or delete a branch/release as cleanup. The [inventory](REPOSITORY_AUDIT.md) records
all refs and release assets before this PR. Any future deletion requires a fresh
inventory of exact refs, unique commits, source provenance, digests and retained
replacement builds presented to the maintainer first. No such deletion is part
of this change. CI builds do not require uploading the Android signing key.
