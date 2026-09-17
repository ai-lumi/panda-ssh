#!/usr/bin/env bash
# 以隔离、可检查的报告运行 Rust 覆盖率门禁。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_DIR="${PANDA_COVERAGE_REPORT_DIR:-$ROOT/target/coverage/gate}"
CORE_REPORT="$REPORT_DIR/panda-core.json"
FFI_REPORT="$REPORT_DIR/panda-ffi.json"

mkdir -p "$REPORT_DIR"
# 先截断固定路径，确保本轮未写出报告时不会读取上一轮产物。
: >"$CORE_REPORT"
: >"$FFI_REPORT"

require_nonempty_report() {
  local report="$1"
  if [[ ! -s "$report" ]]; then
    echo "覆盖率报告缺失或为空：$report" >&2
    exit 1
  fi
}

require_source_file() {
  local report="$1"
  local source_path="$2"
  if ! grep -Fq -- "$source_path" "$report"; then
    echo "覆盖率报告缺少必需源文件：$source_path" >&2
    exit 1
  fi
}

# 清理的范围仅为 cargo-llvm-cov 管理的构建与 profile 产物。两个 package
# 分别运行并由 cargo-llvm-cov 判定 95% 阈值，不依赖跨命令合并 profraw。
cargo llvm-cov clean --workspace

cargo llvm-cov --no-cfg-coverage --package panda-core --tests \
  --json --summary-only --output-path "$CORE_REPORT" \
  --fail-under-lines 95 --fail-under-regions 95

cargo llvm-cov --no-cfg-coverage --package panda-ffi --lib --tests \
  --exclude-from-report panda-core \
  --ignore-filename-regex '(^|/)crates/panda-ffi/src/ffi_adapter\.rs$' \
  --json --summary-only --output-path "$FFI_REPORT" \
  --fail-under-lines 95 --fail-under-regions 95

require_nonempty_report "$CORE_REPORT"
require_nonempty_report "$FFI_REPORT"

# 报告统计域必须互不交叉；否则某个 package 的高覆盖率可能稀释另一个。
require_source_file "$CORE_REPORT" 'crates/panda-core/src/'
if grep -Fq -- 'crates/panda-ffi/' "$CORE_REPORT"; then
  echo "panda-core 覆盖率报告混入 panda-ffi 源文件" >&2
  exit 1
fi
if grep -Fq -- 'crates/panda-core/' "$FFI_REPORT"; then
  echo "panda-ffi 覆盖率报告混入 panda-core 源文件" >&2
  exit 1
fi
if grep -Fq -- 'crates/panda-ffi/src/ffi_adapter.rs' "$FFI_REPORT"; then
  echo "纯值适配器 ffi_adapter.rs 未从覆盖率报告中排除" >&2
  exit 1
fi

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
for filename in "${required_ffi_files[@]}"; do
  require_source_file "$FFI_REPORT" "crates/panda-ffi/src/$filename"
done

echo "Rust 覆盖率门禁通过；报告："
echo "  $CORE_REPORT"
echo "  $FFI_REPORT"
