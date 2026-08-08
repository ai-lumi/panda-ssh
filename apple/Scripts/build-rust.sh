#!/usr/bin/env bash
# Build panda-ffi for Apple platforms and package it as PandaCoreFFI.xcframework,
# then generate the Swift bindings with uniffi-bindgen.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUST_OUT="$ROOT/apple/Rust"
GEN_DIR="$RUST_OUT/Generated"
HEADER_DIR="$RUST_OUT/Headers"
XCFW="$RUST_OUT/PandaCoreFFI.xcframework"

cd "$ROOT"

TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)
for t in "${TARGETS[@]}"; do
  cargo build -p panda-ffi --release --target "$t"
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

rm -rf "$XCFW"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-darwin/release/libpanda_ffi.a" -headers "$HEADER_DIR" \
  -library "target/aarch64-apple-ios/release/libpanda_ffi.a" -headers "$HEADER_DIR" \
  -library "target/aarch64-apple-ios-sim/release/libpanda_ffi.a" -headers "$HEADER_DIR" \
  -output "$XCFW"

echo "==> xcframework: $XCFW"
echo "==> Swift bindings: $GEN_DIR"
