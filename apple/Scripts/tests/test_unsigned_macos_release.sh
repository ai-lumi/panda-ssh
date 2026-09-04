#!/usr/bin/env bash
# 验证无 Developer ID Universal macOS 发布流程的静态契约。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD_SCRIPT="$ROOT/apple/Scripts/build-rust.sh"
PROJECT_FILE="$ROOT/apple/project.yml"
WORKFLOW_FILE="$ROOT/.github/workflows/macos-release.yml"

fail() {
  echo "测试失败：$*" >&2
  exit 1
}

require_text() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file 缺少：$expected"
}

forbid_text() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "$file 不得包含：$unexpected"
  fi
}

# 正常流程：macOS Rust slice 同时覆盖 Apple Silicon 与 Intel。
require_text "$BUILD_SCRIPT" "aarch64-apple-darwin"
require_text "$BUILD_SCRIPT" "x86_64-apple-darwin"
require_text "$BUILD_SCRIPT" 'target/x86_64-apple-darwin/release/libpanda_ffi.a'
require_text "$BUILD_SCRIPT" "lipo -create"
require_text "$BUILD_SCRIPT" "libpanda_ffi-macos-universal.a"

# 边界条件：iOS device 与 simulator 保持既有 arm64 slice，未误加 Intel iOS target。
require_text "$BUILD_SCRIPT" "aarch64-apple-ios"
require_text "$BUILD_SCRIPT" "aarch64-apple-ios-sim"
forbid_text "$BUILD_SCRIPT" "x86_64-apple-ios"

# 意外配置：Release 必须禁用签名并指定两个 macOS App 架构。
require_text "$PROJECT_FILE" 'ARCHS: "arm64 x86_64"'
require_text "$PROJECT_FILE" "CODE_SIGNING_ALLOWED: NO"
forbid_text "$PROJECT_FILE" "CODE_SIGNING_ALLOWED: YES"

# 发布门槛：只由版本标签触发，测试成功后才可打包和创建 Release。
require_text "$WORKFLOW_FILE" 'tags: ["v*"]'
require_text "$WORKFLOW_FILE" "runs-on: macos-15"
require_text "$WORKFLOW_FILE" "cargo test --workspace"
require_text "$WORKFLOW_FILE" "CODE_SIGNING_ALLOWED=NO"
require_text "$WORKFLOW_FILE" "gh release create"
require_text "$WORKFLOW_FILE" "hdiutil create"
require_text "$WORKFLOW_FILE" "ditto -c -k"
require_text "$WORKFLOW_FILE" "-name 'libpanda_ffi*.a'"
require_text "$WORKFLOW_FILE" "Contents/Info.plist"
require_text "$WORKFLOW_FILE" "/usr/libexec/PlistBuddy"
require_text "$WORKFLOW_FILE" "无 Developer ID"
require_text "$WORKFLOW_FILE" "Control 键点击"
forbid_text "$WORKFLOW_FILE" "defaults read"
forbid_text "$WORKFLOW_FILE" "xattr -cr"

echo "无 Developer ID Universal macOS 发布契约验证通过"
