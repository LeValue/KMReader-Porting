#!/usr/bin/env bash
# Build the Kindle worker's CPython 3.11 extensions for all Android ABIs.
set -euo pipefail

recipes="$(cd "$(dirname "$0")" && pwd)"
project="$(cd "$recipes/../.." && pwd)"
output="$project/.dart_tool/android-python-wheels"
ndk="${ANDROID_HOME:?Set ANDROID_HOME}/ndk/28.2.13676358"
test -d "$ndk"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
sources="$scratch/sources"
mkdir -p "$sources" "$output"
cp "$recipes/sources.tsv" "$scratch/inputs"

chaquo="$scratch/chaquopy"
git init -q "$chaquo"
git -C "$chaquo" fetch -q --depth=1 https://github.com/chaquo/chaquopy.git 1f63c93d8beaf7062fbe51888ab9235475df3bb8
git -C "$chaquo" checkout -q --detach FETCH_HEAD
git -C "$chaquo" apply "$recipes/chaquopy.patch"
pypi="$chaquo/server/pypi"
export PIP_DISABLE_PIP_VERSION_CHECK=1
python3.11 -m pip install --target "$scratch/tools" -r "$pypi/requirements.txt" \
  'patchelf==0.19.3.0' 'cmake==4.4.5' 'ninja==1.13.2'
export PATH="$scratch/tools/bin:$PATH" PYTHONPATH="$scratch/tools"

while read -r archive checksum url; do
  curl -fLsS --retry 3 "$url" -o "$sources/$archive"
  printf '%s  %s\n' "$checksum" "$sources/$archive" | sha256sum -c -
  name="${archive%.tar.*}"
  mkdir -p "$sources/$name"
  tar xf "$sources/$archive" --strip-components=1 -C "$sources/$name"
done < "$scratch/inputs"

abis=(arm64-v8a armeabi-v7a x86_64)
python_target="3.11.17-0"
maven="$chaquo/maven/com/chaquo/python/target/$python_target"
mkdir -p "$maven"
for abi in "${abis[@]}"; do
  file="target-$python_target-$abi.zip"
  url="https://repo.maven.apache.org/maven2/com/chaquo/python/target/$python_target/$file"
  curl -fLsS --retry 3 "$url" -o "$maven/$file"
  checksum="$(curl -fLsS --retry 3 "$url.sha1")"
  printf '%s  %s\n' "$checksum" "$maven/$file" | sha1sum -c -
done

for item in pillow:13.0.0 lxml:6.1.1; do
  package="${item%%:*}"
  version="${item#*:}"
  package_recipe="$pypi/packages/$package"
  printf 'package:\n  name: %s\n  version: "%s"\n' "$package" "$version" > "$package_recipe/meta.yaml"
  mkdir -p "$package_recipe/build/$version"
  cp "$sources/$package-$version.tar.gz" "$package_recipe/build/$version/"
done
cp "$recipes/pillow.patch" "$pypi/packages/pillow/patches/chaquopy.patch"

build_library() {
  local name="$1"
  shift
  local dir="$scratch/build/$abi/$name"
  cmake -S "$sources/$name" -B "$dir" -GNinja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" -DANDROID_PLATFORM=android-24 \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$prefix" "$@"
  cmake --build "$dir" --parallel "${KMREADER_NATIVE_JOBS:-3}"
  cmake --install "$dir"
}

cd "$pypi"
for abi in "${abis[@]}"; do
  prefix="$pypi/native-prefix/$abi"
  build_library libjpeg-turbo-3.1.3 -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_SIMD=OFF -DWITH_TESTS=OFF -DWITH_TOOLS=OFF
  build_library freetype-2.14.2 -DBUILD_SHARED_LIBS=OFF -DFT_DISABLE_ZLIB=TRUE -DFT_DISABLE_BZIP2=TRUE -DFT_DISABLE_PNG=TRUE -DFT_DISABLE_HARFBUZZ=TRUE -DFT_DISABLE_BROTLI=TRUE
  build_library libxml2-2.15.3 -DBUILD_SHARED_LIBS=OFF -DLIBXML2_WITH_ICONV=OFF -DLIBXML2_WITH_PROGRAMS=OFF -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_MODULES=OFF -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_ZLIB=OFF
  build_library libxslt-1.1.45 -DBUILD_SHARED_LIBS=OFF -DLIBXSLT_WITH_PROGRAMS=OFF -DLIBXSLT_WITH_TESTS=OFF -DLIBXSLT_WITH_PYTHON=OFF -DLIBXSLT_WITH_CRYPTO=OFF -DLibXml2_DIR="$prefix/lib/cmake/libxml2"
  python3.11 build-wheel.py --python 3.11 --abi "$abi" pillow
  python3.11 build-wheel.py --python 3.11 --abi "$abi" lxml
done

for wheel_file in "$pypi"/dist/{pillow,lxml}/*.whl; do
  unpack="$scratch/wheels"
  mkdir -p "$unpack"
  wheel unpack "$wheel_file" -d "$unpack"
  package="$(basename "$wheel_file")"
  name="${package%%-*}"
  case "$name" in
    pillow)
      package_dir="$unpack/pillow-13.0.0"
      license_dir="$package_dir/pillow-13.0.0.dist-info/licenses"
      mkdir -p "$license_dir"
      cp "$sources/libjpeg-turbo-3.1.3/LICENSE.md" "$license_dir/libjpeg-turbo-LICENSE.md"
      cp "$sources/libjpeg-turbo-3.1.3/README.ijg" "$license_dir/libjpeg-turbo-README.ijg"
      cp "$sources/freetype-2.14.2/docs/FTL.TXT" "$license_dir/FreeType-LICENSE.txt"
      ;;
    lxml)
      package_dir="$unpack/lxml-6.1.1"
      license_dir="$package_dir/lxml-6.1.1.dist-info/licenses"
      mkdir -p "$license_dir"
      cp "$sources/libxml2-2.15.3/Copyright" "$license_dir/libxml2-Copyright"
      cp "$sources/libxslt-1.1.45/Copyright" "$license_dir/libxslt-Copyright"
      ;;
  esac
  wheel pack "$package_dir" -d "$output"
  rm -rf -- "$package_dir"
done
test "$(find "$output" -maxdepth 1 -name '*.whl' | wc -l)" -eq 6
