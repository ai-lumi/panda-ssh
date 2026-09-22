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
require_text "--ignore-filename-regex '(^|/)crates/panda-ffi/src/(ffi_adapter\\.rs|test_support\\.rs|tests/.*)$'"
require_text 'src/tests/'
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
require_text 'ffi-contract-matrix.txt'
require_text 'require_contract_matrix'

# raw LLVM regions 只保留为 FFI 的诊断信息；regions 阈值只能属于
# panda-core 命令，不能重新进入 panda-ffi 的通过条件。
if [[ "$(grep -Fc -- '--fail-under-lines 95 --fail-under-regions 95' "$SCRIPT")" -ne 1 ]]; then
  echo "FFI 覆盖率门禁不应以 raw regions 作为通过条件" >&2
  exit 1
fi

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

write_report() {
  local destination="$1"
  shift
  local separator=""
  printf '{"data":[{"files":[' >"$destination"
  local filename
  for filename in "$@"; do
    printf '%s{"filename":"%s","summary":{"lines":{"percent":100},"regions":{"percent":100}}}' \
      "$separator" "$filename" >>"$destination"
    separator=","
  done
  printf ']}]}\n' >>"$destination"
}

CORE_REPORT="$TEST_TMP/core.json"
FFI_REPORT="$TEST_TMP/ffi.json"
FFI_MISSING_REPORT="$TEST_TMP/ffi-missing.json"
FFI_CROSS_REPORT="$TEST_TMP/ffi-cross.json"
FFI_ADAPTER_REPORT="$TEST_TMP/ffi-adapter.json"
FFI_LOW_FILE_REPORT="$TEST_TMP/ffi-low-file.json"
FFI_LOW_LINES_REPORT="$TEST_TMP/ffi-low-lines.json"
FFI_TEST_SOURCE_REPORT="$TEST_TMP/ffi-test-source.json"

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
write_report "$FFI_TEST_SOURCE_REPORT" "${ffi_paths[@]}" "/repo/crates/panda-ffi/src/tests/ffi_sessions_tests.rs"

write_report_with_low_file_coverage() {
  local destination="$1"
  printf '{"data":[{"files":[' >"$destination"
  local separator=""
  local filename
  for filename in "${required_ffi_files[@]}"; do
    local summary='{"lines":{"percent":100},"regions":{"percent":100}}'
    if [[ "$filename" == "ffi_sessions.rs" ]]; then
      summary='{"lines":{"percent":100},"regions":{"percent":94}}'
    fi
    printf '%s{"filename":"/repo/crates/panda-ffi/src/%s","summary":%s}' \
      "$separator" "$filename" "$summary" >>"$destination"
    separator=","
  done
  printf ']}]}\n' >>"$destination"
}
write_report_with_low_file_coverage "$FFI_LOW_FILE_REPORT"

write_report_with_low_lines_coverage() {
  local destination="$1"
  printf '{"data":[{"files":[' >"$destination"
  local separator=""
  local filename
  for filename in "${required_ffi_files[@]}"; do
    local summary='{"lines":{"percent":100},"regions":{"percent":100}}'
    if [[ "$filename" == "ffi_sessions.rs" ]]; then
      summary='{"lines":{"percent":94},"regions":{"percent":100}}'
    fi
    printf '%s{"filename":"/repo/crates/panda-ffi/src/%s","summary":%s}' \
      "$separator" "$filename" "$summary" >>"$destination"
    separator=","
  done
  printf ']}]}\n' >>"$destination"
}
write_report_with_low_lines_coverage "$FFI_LOW_LINES_REPORT"

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

if PANDA_COVERAGE_REPORT_DIR="$TEST_TMP/test-source" \
  MOCK_FFI_REPORT="$FFI_TEST_SOURCE_REPORT" bash "$SCRIPT" >/dev/null 2>&1; then
  echo "FFI 报告混入测试专用源码时覆盖率门禁仍然通过" >&2
  exit 1
fi

if ! PANDA_COVERAGE_REPORT_DIR="$TEST_TMP/low-file" \
  MOCK_FFI_REPORT="$FFI_LOW_FILE_REPORT" bash "$SCRIPT" >/dev/null 2>&1; then
  echo "单个业务 FFI 文件仅 regions 低于 95% 时覆盖率门禁不应失败" >&2
  exit 1
fi

if PANDA_COVERAGE_REPORT_DIR="$TEST_TMP/low-lines" \
  MOCK_FFI_REPORT="$FFI_LOW_LINES_REPORT" bash "$SCRIPT" >"$TEST_TMP/low-lines.out" 2>&1; then
  echo "单个业务 FFI 文件 lines 低于 95% 时覆盖率门禁仍然通过" >&2
  exit 1
fi
grep -Fq 'ffi_sessions.rs' "$TEST_TMP/low-lines.out" || {
  echo "覆盖率门禁未指出低于阈值的业务 FFI 文件" >&2
  exit 1
}

if PANDA_COVERAGE_REPORT_DIR="$TEST_TMP/cargo-failure" \
  MOCK_CARGO_FAIL_PACKAGE="panda-ffi" bash "$SCRIPT" >/dev/null 2>&1; then
  echo "cargo llvm-cov 失败时覆盖率门禁仍然通过" >&2
  exit 1
fi

if PANDA_COVERAGE_REPORT_DIR="$TEST_TMP/missing-contract-matrix" \
  PANDA_FFI_CONTRACT_MATRIX="$TEST_TMP/no-such-matrix" bash "$SCRIPT" >"$TEST_TMP/missing-contract-matrix.out" 2>&1; then
  echo "缺少 FFI 契约测试矩阵时覆盖率门禁仍然通过" >&2
  exit 1
fi
grep -Fq 'FFI 契约测试矩阵' "$TEST_TMP/missing-contract-matrix.out" || {
  echo "覆盖率门禁未指出缺失的 FFI 契约测试矩阵" >&2
  exit 1
}
