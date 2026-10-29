# Verified development previews

The version in `pubspec.yaml` and `lib/core/app_version.dart` must agree.
Increment the Android build number for every published update and add notes at
`docs/releases/v<version>-preview.1.md`. `tool/preview_metadata.py` checks these
values before CI builds or publication.

Commit the source, then run `python3 tool/prepare_build_metadata.py` to generate
the embedded source/version record. CI does this for both platforms too.
Build Android with the retained, private signing configuration. The key is not
uploaded to CI. Produce complete APKs for all three architectures:

```sh
env 'ORG_GRADLE_PROJECT_force-version-code-ignoring-abi=true' \
  ORG_GRADLE_PROJECT_kmreaderPreview=true \
  flutter build apk --release --split-per-abi
```

The explicit version-code flag keeps each architecture on the same increasing
build number, preserving upgrade compatibility with the older universal APK.
`--target-platform` alone is insufficient: third-party native libraries may
still be packaged for architectures without a matching Flutter engine. Check
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
