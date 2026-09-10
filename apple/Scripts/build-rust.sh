#!/usr/bin/env bash
# Build panda-ffi for Apple platforms and package it as PandaCoreFFI.xcframework,
# then generate the Swift bindings with uniffi-bindgen.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUST_OUT="$ROOT/apple/Rust"
GEN_DIR="$RUST_OUT/Generated"
HEADER_DIR="$RUST_OUT/Headers"
XCFW="$RUST_OUT/PandaCoreFFI.xcframework"
MACOS_UNIVERSAL_LIB="$RUST_OUT/libpanda_ffi-macos-universal.a"

# 最低部署目标,必须与 apple/project.yml 的 options.deploymentTarget 保持一致。
# 环境变量不参与 cargo 产物指纹:在缺失环境变量时构建过的产物会被直接复用,
# 其中 C 依赖(cc crate)回落到 SDK 版本、Rust 代码回落到编译器默认最低版本,
# 链接进 App 时触发 "was built for newer 'macOS' version" 警告。
# 因此构建前校验 aws-lc 对象的版本戳,不匹配则清理该 target 目录强制重建。
MACOS_MIN="14.0"
IOS_MIN="17.0"

cd "$ROOT"

# 输出对象文件版本戳(minos / version)的前两段;无法识别时输出空
stamp_of() {
  otool -l "$1" 2>/dev/null | awk '
    /LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX|LC_VERSION_MIN_IPHONEOS/ {ins = 1; next}
    ins && $1 == "minos"   {print $2; exit}
    ins && $1 == "version" {print $2; exit}
  ' | cut -d. -f1,2 || true
}

# 取一个 aws-lc-sys 的 C 对象作为整个 C 依赖的版本戳样本
# 注意:-path 匹配完整路径,前导 * 不能省,否则永远匹配不到
aws_lc_object() {
  find "target/$1/release/build" -path '*aws-lc-sys-*/out/*.o' -print 2>/dev/null | head -n1 || true
}

check_stamp() {  # $1=triple $2=期望版本;找不到 C 依赖对象时视为通过
  local obj got
  obj="$(aws_lc_object "$1")"
  [[ -n "$obj" ]] || return 0
  got="$(stamp_of "$obj")"
  [[ "$got" == "$2" ]]
}

build_ffi() {  # $1=triple $2=部署目标环境变量名 $3=版本
  if ! check_stamp "$1" "$3"; then
    echo "==> $1 存在错误部署目标版本戳的陈旧产物,清理后重建"
    rm -rf "target/$1"
  fi
  env "$2=$3" cargo build -p panda-ffi --release --target "$1"
  if ! check_stamp "$1" "$3"; then
    echo "错误:$1 的 aws-lc 对象版本戳仍与期望 $3 不符,部署目标环境变量可能未生效" >&2
    exit 1
  fi
}

MACOS_TARGETS=(
  aarch64-apple-darwin
  x86_64-apple-darwin
)
for t in "${MACOS_TARGETS[@]}"; do
  build_ffi "$t" MACOSX_DEPLOYMENT_TARGET "$MACOS_MIN"
done

IOS_TARGETS=(
  aarch64-apple-ios
  aarch64-apple-ios-sim
)
for t in "${IOS_TARGETS[@]}"; do
  build_ffi "$t" IPHONEOS_DEPLOYMENT_TARGET "$IOS_MIN"
done

# Generate Swift bindings + C header + module map from the macOS dylib artifact.
# uniffi-bindgen is a bin target inside panda-ffi (see crates/panda-ffi/src/bin).
mkdir -p "$GEN_DIR" "$HEADER_DIR"
cargo run -p panda-ffi --release --features bindgen-cli --bin uniffi-bindgen -- \
  generate \
  --library "target/aarch64-apple-darwin/release/libpanda_ffi.dylib" \
  --language swift \
  --out-dir "$GEN_DIR"

# Move the generated header/module map next to the libraries for the xcframework.
cp "$GEN_DIR"/*.h "$HEADER_DIR"/
cp "$GEN_DIR"/*.modulemap "$HEADER_DIR"/module.modulemap

lipo -create \
  "target/aarch64-apple-darwin/release/libpanda_ffi.a" \
  "target/x86_64-apple-darwin/release/libpanda_ffi.a" \
  -output "$MACOS_UNIVERSAL_LIB"

rm -rf "$XCFW"
xcodebuild -create-xcframework \
  -library "$MACOS_UNIVERSAL_LIB" -headers "$HEADER_DIR" \
  -library "target/aarch64-apple-ios/release/libpanda_ffi.a" -headers "$HEADER_DIR" \
  -library "target/aarch64-apple-ios-sim/release/libpanda_ffi.a" -headers "$HEADER_DIR" \
  -output "$XCFW"

rm -f "$MACOS_UNIVERSAL_LIB"

echo "==> xcframework: $XCFW"
echo "==> Swift bindings: $GEN_DIR"
