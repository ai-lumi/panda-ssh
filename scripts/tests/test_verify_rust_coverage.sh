#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/verify-rust-coverage.sh"

require_text() {
  local needle="$1"
  grep -Fq -- "$needle" "$SCRIPT" || {
    echo "缺少覆盖率门禁契约：$needle" >&2
    exit 1
  }
}

if [[ ! -f "$SCRIPT" ]]; then
  echo "缺少覆盖率门禁脚本：$SCRIPT" >&2
  exit 1
fi

require_text 'cargo llvm-cov clean --workspace'
require_text 'cargo llvm-cov --no-cfg-coverage --package panda-core --tests'
require_text 'cargo llvm-cov --no-cfg-coverage --package panda-ffi --lib --tests'
require_text "--exclude-from-report panda-core"
require_text "--ignore-filename-regex '(^|/)crates/panda-ffi/src/ffi_adapter\\.rs$'"
require_text '--fail-under-lines 95 --fail-under-regions 95'
require_text '--json'
require_text '--summary-only'
require_text '--output-path'
require_text 'ffi_runtime.rs'
require_text 'ffi_sessions.rs'
require_text 'ffi_store.rs'
require_text 'ffi_telemetry.rs'
require_text 'ffi_transfers.rs'
require_text 'ffi_workspace.rs'
require_text 'batch_transfer.rs'
require_text 'task_aggregation.rs'

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

write_report() {
  local destination="$1"
  shift
  local separator=""
  printf '{"data":[{"files":[' >"$destination"
  local filename
  for filename in "$@"; do
    printf '%s{"filename":"%s"}' "$separator" "$filename" >>"$destination"
    separator=","
  done
  printf ']}]}\n' >>"$destination"
}

CORE_REPORT="$TEST_TMP/core.json"
FFI_REPORT="$TEST_TMP/ffi.json"
FFI_MISSING_REPORT="$TEST_TMP/ffi-missing.json"
FFI_CROSS_REPORT="$TEST_TMP/ffi-cross.json"
FFI_ADAPTER_REPORT="$TEST_TMP/ffi-adapter.json"

required_ffi_files=(
  lib.rs
  ffi_runtime.rs
  ffi_sessions.rs
  ffi_store.rs
  ffi_telemetry.rs
  ffi_transfers.rs
  ffi_workspace.rs
  batch_transfer.rs
  task_aggregation.rs
)

write_report "$CORE_REPORT" "/repo/crates/panda-core/src/lib.rs"

ffi_paths=()
for filename in "${required_ffi_files[@]}"; do
  ffi_paths+=("/repo/crates/panda-ffi/src/$filename")
done
write_report "$FFI_REPORT" "${ffi_paths[@]}"

missing_paths=()
for filename in "${required_ffi_files[@]}"; do
  [[ "$filename" == "ffi_workspace.rs" ]] || missing_paths+=("/repo/crates/panda-ffi/src/$filename")
done
write_report "$FFI_MISSING_REPORT" "${missing_paths[@]}"
write_report "$FFI_CROSS_REPORT" "${ffi_paths[@]}" "/repo/crates/panda-core/src/lib.rs"
write_report "$FFI_ADAPTER_REPORT" "${ffi_paths[@]}" "/repo/crates/panda-ffi/src/ffi_adapter.rs"

cargo() {
  printf '%s\n' "$*" >>"$MOCK_CARGO_LOG"
  if [[ "$*" == "llvm-cov clean --workspace" ]]; then
    return 0
  fi

  local output_path=""
  local package=""
  local previous=""
  local argument
  for argument in "$@"; do
    case "$previous" in
      --output-path) output_path="$argument" ;;
      --package) package="$argument" ;;
    esac
    previous="$argument"
  done

  if [[ -n "${MOCK_CARGO_FAIL_PACKAGE:-}" && "$package" == "$MOCK_CARGO_FAIL_PACKAGE" ]]; then
    return 17
  fi
  if [[ -n "${MOCK_CARGO_SKIP_REPORT_PACKAGE:-}" && "$package" == "$MOCK_CARGO_SKIP_REPORT_PACKAGE" ]]; then
    return 0
  fi
  case "$package" in
    panda-core) cp "$MOCK_CORE_REPORT" "$output_path" ;;
    panda-ffi) cp "$MOCK_FFI_REPORT" "$output_path" ;;
    *) echo "mock cargo 收到未知 package：$package" >&2; return 18 ;;
  esac
}
export -f cargo
export MOCK_CARGO_LOG="$TEST_TMP/cargo.log"
export MOCK_CORE_REPORT="$CORE_REPORT"
export MOCK_FFI_REPORT="$FFI_REPORT"

PANDA_COVERAGE_REPORT_DIR="$TEST_TMP/happy" bash "$SCRIPT" >/dev/null

# 复用同一报告目录时，本轮未产出报告不得读取上一轮遗留 JSON。
if PANDA_COVERAGE_REPORT_DIR="$TEST_TMP/happy" \
  MOCK_CARGO_SKIP_REPORT_PACKAGE="panda-ffi" bash "$SCRIPT" >/dev/null 2>&1; then
  echo "本轮未生成 FFI 报告时门禁读取了旧报告" >&2
  exit 1
fi

if PANDA_COVERAGE_REPORT_DIR="$TEST_TMP/missing" \
  MOCK_FFI_REPORT="$FFI_MISSING_REPORT" bash "$SCRIPT" >"$TEST_TMP/missing.out" 2>&1; then
  echo "业务 FFI 文件缺失时覆盖率门禁仍然通过" >&2
  exit 1
fi
grep -Fq 'ffi_workspace.rs' "$TEST_TMP/missing.out" || {
  echo "覆盖率门禁未指出缺失的业务 FFI 文件" >&2
  exit 1
}

if PANDA_COVERAGE_REPORT_DIR="$TEST_TMP/cross" \
  MOCK_FFI_REPORT="$FFI_CROSS_REPORT" bash "$SCRIPT" >/dev/null 2>&1; then
  echo "FFI 报告混入 panda-core 时覆盖率门禁仍然通过" >&2
  exit 1
fi

if PANDA_COVERAGE_REPORT_DIR="$TEST_TMP/adapter" \
  MOCK_FFI_REPORT="$FFI_ADAPTER_REPORT" bash "$SCRIPT" >/dev/null 2>&1; then
  echo "ffi_adapter 仍在报告中时覆盖率门禁仍然通过" >&2
  exit 1
fi

if PANDA_COVERAGE_REPORT_DIR="$TEST_TMP/cargo-failure" \
  MOCK_CARGO_FAIL_PACKAGE="panda-ffi" bash "$SCRIPT" >/dev/null 2>&1; then
  echo "cargo llvm-cov 失败时覆盖率门禁仍然通过" >&2
  exit 1
fi
