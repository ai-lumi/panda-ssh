#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKS="$SCRIPT_DIR/../_ffi_module_boundaries_checks.sh"

[[ -f "$CHECKS" ]] || {
  echo "缺少边界检查文件：$CHECKS" >&2
  exit 1
}

bash "$CHECKS"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

# --- 意外：核心反向依赖 FFI（Cargo.toml 声明 panda-ffi 依赖） ---
mkdir -p "$TEST_TMP/t1/crates/panda-ffi/src" "$TEST_TMP/t1/crates/panda-core/src"
touch "$TEST_TMP/t1/crates/panda-ffi/src/ffi_runtime.rs"
printf 'panda-ffi = { path = "../panda-ffi" }\n' > "$TEST_TMP/t1/crates/panda-core/Cargo.toml"
if FFI_BOUNDARIES_ROOT="$TEST_TMP/t1" bash "$CHECKS" 2>/dev/null; then
  echo "核心 Cargo.toml 声明 panda-ffi 依赖时边界检查仍通过" >&2
  exit 1
fi

# --- 意外：核心源码反向引用 FFI ---
mkdir -p "$TEST_TMP/t2/crates/panda-ffi/src" "$TEST_TMP/t2/crates/panda-core/src"
touch "$TEST_TMP/t2/crates/panda-ffi/src/ffi_runtime.rs"
printf '[dependencies]\n' > "$TEST_TMP/t2/crates/panda-core/Cargo.toml"
printf 'use panda_ffi::PandaError;\n' > "$TEST_TMP/t2/crates/panda-core/src/lib.rs"
if FFI_BOUNDARIES_ROOT="$TEST_TMP/t2" bash "$CHECKS" 2>/dev/null; then
  echo "核心源码引用 panda_ffi 时边界检查仍通过" >&2
  exit 1
fi

# --- 边界：必需 FFI 文件缺失 ---
mkdir -p "$TEST_TMP/t3/crates/panda-ffi/src/tests" \
  "$TEST_TMP/t3/crates/panda-core/src"
touch "$TEST_TMP/t3/crates/panda-ffi/src/ffi_runtime.rs"
printf '[dependencies]\n' > "$TEST_TMP/t3/crates/panda-core/Cargo.toml"
printf 'mod batch_transfer;\npub use batch_transfer::start;\n' \
  > "$TEST_TMP/t3/crates/panda-ffi/src/ffi_transfers.rs"
printf '#[path = "batch_transfer.rs"]\nmod batch_transfer;\npub use batch_transfer::start;\n' \
  > "$TEST_TMP/t3/crates/panda-ffi/src/ffi_transfers.rs"
printf '#[path = "task_aggregation.rs"]\nmod task_aggregation;\npub use task_aggregation::aggregate;\n' \
  >> "$TEST_TMP/t3/crates/panda-ffi/src/ffi_transfers.rs"
touch "$TEST_TMP/t3/crates/panda-ffi/src/lib.rs"
touch "$TEST_TMP/t3/crates/panda-ffi/src/tests/ffi_sessions_tests.rs" \
  "$TEST_TMP/t3/crates/panda-ffi/src/tests/ffi_store_tests.rs" \
  "$TEST_TMP/t3/crates/panda-ffi/src/tests/ffi_transfers_tests.rs" \
  "$TEST_TMP/t3/crates/panda-ffi/src/tests/ffi_telemetry_tests.rs" \
  "$TEST_TMP/t3/crates/panda-ffi/src/tests/ffi_workspace_tests.rs" \
  "$TEST_TMP/t3/crates/panda-ffi/src/tests/batch_transfer_tests.rs"
for f in \
  "$TEST_TMP/t3/crates/panda-ffi/src/tests/ffi_sessions_tests.rs" \
  "$TEST_TMP/t3/crates/panda-ffi/src/tests/ffi_store_tests.rs" \
  "$TEST_TMP/t3/crates/panda-ffi/src/tests/ffi_transfers_tests.rs" \
  "$TEST_TMP/t3/crates/panda-ffi/src/tests/ffi_telemetry_tests.rs" \
  "$TEST_TMP/t3/crates/panda-ffi/src/tests/ffi_workspace_tests.rs" \
  "$TEST_TMP/t3/crates/panda-ffi/src/tests/batch_transfer_tests.rs"; do
  printf 'test_support::global_test_lock\n' > "$f"
done
if FFI_BOUNDARIES_ROOT="$TEST_TMP/t3" bash "$CHECKS" 2>/dev/null; then
  echo "缺少 ffi_delete.rs 时边界检查仍通过" >&2
  exit 1
fi

# --- 边界：runtime 模块缺失 ---
mkdir -p "$TEST_TMP/t4/crates/panda-ffi/src" "$TEST_TMP/t4/crates/panda-core/src"
touch "$TEST_TMP/t4/crates/panda-ffi/src/lib.rs"
printf '[dependencies]\n' > "$TEST_TMP/t4/crates/panda-core/Cargo.toml"
if FFI_BOUNDARIES_ROOT="$TEST_TMP/t4" bash "$CHECKS" 2>/dev/null; then
  echo "缺少 ffi_runtime.rs 时边界检查仍通过" >&2
  exit 1
fi
