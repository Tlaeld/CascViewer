#!/bin/bash
# 构建 WhiteoutLib universal(arm64 + x86_64)静态库。
# 只启用核心库(textures + models),不启用 CASC/MPQ(项目用 CascLib)。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=WhiteoutLib
COMMON_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DWHITEOUT_ENABLE_CASC=OFF
  -DWHITEOUT_ENABLE_MPQ=OFF
  -DWHITEOUT_BUILD_TESTS=OFF
  -DWHITEOUT_BUILD_EXAMPLES=OFF
  -DWHITEOUT_WARNINGS_AS_ERRORS=OFF
  -DWHITEOUT_INSTALL=OFF
)

for ARCH in arm64 x86_64; do
  cmake -S "$SRC" -B "$SRC/build-$ARCH" "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
  cmake --build "$SRC/build-$ARCH" --target whiteout_lib -j 12
done

mkdir -p "$SRC/build-universal"
lipo -create \
  "$SRC/build-arm64/libwhiteout_lib.a" \
  "$SRC/build-x86_64/libwhiteout_lib.a" \
  -output "$SRC/build-universal/libwhiteout_lib.a"

echo "OK: $SRC/build-universal/libwhiteout_lib.a"
lipo -info "$SRC/build-universal/libwhiteout_lib.a"
