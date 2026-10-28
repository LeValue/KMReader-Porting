#!/usr/bin/env bash
set -euo pipefail

# CI sometimes receives a truncated SDK archive. Retry the disposable install,
# never a corrupt staging directory, before starting Gradle or the emulator.
km_ndk_version=28.2.13676358
km_ndk_root="${ANDROID_HOME:?Android SDK is required}/ndk/$km_ndk_version"
# Only a disposable Actions runner may discard its unused preinstalled NDKs.
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  for km_unused_ndk in "$ANDROID_HOME"/ndk/*; do
    if [[ -d "$km_unused_ndk" && "$km_unused_ndk" != "$km_ndk_root" ]]; then
      rm -rf -- "$km_unused_ndk"
    fi
  done
fi

km_ndk_ready() {
  [[ -f "$km_ndk_root/source.properties" &&
     -x "$km_ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" &&
     -f "$km_ndk_root/build/cmake/android.toolchain.cmake" ]]
}
if km_ndk_ready; then exit 0; fi

for km_ndk_attempt in 1 2 3; do
  if timeout --signal=TERM --kill-after=20s 5m sdkmanager --install "ndk;$km_ndk_version" && km_ndk_ready; then
    exit 0
  fi
  echo "NDK installation attempt $km_ndk_attempt did not complete; clearing only its disposable SDK staging data."
  if [[ -d "$ANDROID_HOME/.temp" ]]; then
    find "$ANDROID_HOME/.temp" -mindepth 1 -maxdepth 1 -type d -name 'PackageOperation*' -exec rm -rf -- {} +
  fi
  if ! km_ndk_ready; then rm -rf -- "$km_ndk_root"; fi
done
echo 'The pinned NDK could not be installed after three attempts.' >&2
exit 1
