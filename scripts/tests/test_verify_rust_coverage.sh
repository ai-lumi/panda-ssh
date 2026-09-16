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
require_text "--ignore-filename-regex 'ffi_adapter'"
require_text '--fail-under-lines 95 --fail-under-regions 95'
