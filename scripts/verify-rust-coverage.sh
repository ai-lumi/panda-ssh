#!/usr/bin/env bash
# 以隔离的 profile 生命周期运行 Rust 覆盖率门禁。
set -euo pipefail

# 清理的范围仅为 cargo-llvm-cov 管理的覆盖率构建与 profile 产物。
cargo llvm-cov clean --workspace

# fake-server 测试按 crate 独立判定，避免 workspace 单次运行遗漏 FFI profile。
cargo llvm-cov --no-cfg-coverage --package panda-core --tests \
  --fail-under-lines 95 --fail-under-regions 95
cargo llvm-cov --no-cfg-coverage --package panda-ffi --lib --tests \
  --ignore-filename-regex 'ffi_adapter' \
  --fail-under-lines 95 --fail-under-regions 95
