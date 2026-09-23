#!/usr/bin/env bash
# FFI module boundary positive checks (sourced by test_ffi_module_boundaries.sh).
# Accepts env var overrides for negative fixture tests.
set -euo pipefail

ROOT="${FFI_BOUNDARIES_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="${FFI_BOUNDARIES_LIB:-$ROOT/crates/panda-ffi/src/lib.rs}"
TRANSFERS="${FFI_BOUNDARIES_TRANSFERS:-$ROOT/crates/panda-ffi/src/ffi_transfers.rs}"
CORE_CARGO="${FFI_BOUNDARIES_CORE_CARGO:-$ROOT/crates/panda-core/Cargo.toml}"

require_text() {
  local needle="$1"
  local file="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "MISSING FFI boundary contract: $file: $needle" >&2
    exit 1
  fi
}

reject_text() {
  local needle="$1"
  local file="$2"
  if grep -Fq -- "$needle" "$file"; then
    echo "FFI boundary violation: $file: $needle" >&2
    exit 1
  fi
}

if [[ ! -f "$ROOT/crates/panda-ffi/src/ffi_runtime.rs" ]]; then
  echo "Missing independent runtime module" >&2
  exit 1
fi

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

for entry in \
  "tests/ffi_sessions_tests.rs" \
  "tests/ffi_store_tests.rs" \
  "tests/ffi_transfers_tests.rs" \
  "tests/ffi_telemetry_tests.rs" \
  "tests/ffi_workspace_tests.rs" \
  "tests/batch_transfer_tests.rs" \
  "ffi_delete.rs"; do
  require_text 'test_support::global_test_lock' "$ROOT/crates/panda-ffi/src/$entry"
done

reject_text 'panda-ffi' "$CORE_CARGO"

for src in "$ROOT"/crates/panda-core/src/*.rs; do
  [[ -f "$src" ]] || continue
  reject_text 'use panda_ffi::' "$src"
  reject_text 'use crate::ffi_' "$src"
done
