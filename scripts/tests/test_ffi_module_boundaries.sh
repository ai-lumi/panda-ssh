#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/crates/panda-ffi/src/lib.rs"
TRANSFERS="$ROOT/crates/panda-ffi/src/ffi_transfers.rs"

require_text() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || {
    echo "缺少 FFI 模块边界契约：$file: $needle" >&2
    exit 1
  }
}

reject_text() {
  local needle="$1"
  local file="$2"
  if grep -Fq -- "$needle" "$file"; then
    echo "FFI 根模块仍包含内部依赖中转：$file: $needle" >&2
    exit 1
  fi
}

[[ -f "$ROOT/crates/panda-ffi/src/ffi_runtime.rs" ]] || {
  echo "缺少独立 runtime 模块" >&2
  exit 1
}

require_text '#[path = "batch_transfer.rs"]' "$TRANSFERS"
require_text 'mod batch_transfer;' "$TRANSFERS"
require_text '#[path = "task_aggregation.rs"]' "$TRANSFERS"
require_text 'mod task_aggregation;' "$TRANSFERS"
require_text 'pub use batch_transfer::' "$TRANSFERS"
require_text 'pub use task_aggregation::' "$TRANSFERS"

reject_text 'mod batch_transfer;' "$LIB"
reject_text 'mod task_aggregation;' "$LIB"
reject_text 'pub(crate) use ffi_store::' "$LIB"
reject_text 'pub(crate) use ffi_transfers::notify_transfer_changed' "$LIB"
reject_text 'static RUNTIME:' "$LIB"

for file in ffi_store.rs ffi_transfers.rs ffi_telemetry.rs ffi_workspace.rs; do
  require_text 'test_support::global_test_lock' "$ROOT/crates/panda-ffi/src/$file"
done
