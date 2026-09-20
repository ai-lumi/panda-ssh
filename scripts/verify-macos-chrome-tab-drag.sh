#!/bin/bash
# macOS 人工验收脚本：fix-macos-tab-drag-and-titlebar-zoom
# 用法：bash scripts/verify-macos-chrome-tab-drag.sh
# 不得连接真实 SSH 主机或读取凭据。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APPLE_DIR="$PROJECT_ROOT/apple"

echo "=== 构建 Rust 静态库 ==="
export PATH="$HOME/.cargo/bin:$PATH"
bash "$APPLE_DIR/Scripts/build-rust.sh"

echo "=== 生成 Xcode 工程 ==="
(cd "$APPLE_DIR" && xcodegen)

echo "=== 构建 macOS 应用 ==="
xcodebuild -project "$APPLE_DIR/PandaSSH.xcodeproj" \
    -scheme PandaSSH-macOS \
    -destination 'platform=macOS' \
    build 2>&1 | tail -5

echo "=== 运行自动化 XCTest ==="
xcodebuild -project "$APPLE_DIR/PandaSSH.xcodeproj" \
    -scheme PandaSSH-macOS \
    -destination 'platform=macOS' \
    test \
    -only-testing:"PandaSSH-macOSTests/WorkspaceChromeEventBridgeTests" \
    -only-testing:"PandaSSH-macOSTests/WorkspaceTabDragTransactionTests" \
    -only-testing:"PandaSSH-macOSTests/MainWindowChromeLifecycleTests" \
    -only-testing:"PandaSSH-macOSTests/WorkspaceStoreSortTests" \
    -only-testing:"PandaSSH-macOSTests/WorkspaceStoreGroupTests" \
    2>&1 | grep -E "Executed|passed|failed" | tail -10

echo ""
echo "=== 人工验收步骤 ==="
echo "请启动应用并按以下步骤操作："
echo ""
echo "1. 正常流程："
echo "   a. 打开 3+ 页签（使用 Mock 后端或添加主机后连接）"
echo "   b. 拖动页签到另一个位置 → 确认页签顺序更新"
echo "   c. 双击顶部空白区（红绿灯右侧或最右空白处）→ 确认窗口缩放"
echo "   d. 再次双击 → 确认窗口还原"
echo ""
echo "2. 意外操作："
echo "   a. 开始拖动页签后拖出页签栏释放 → 确认顺序恢复"
echo "   b. 双击页签 → 确认不缩放窗口"
echo "   c. 双击关闭按钮 → 确认只关闭页签不缩放"
echo "   d. 双击侧栏按钮 → 确认只触发按钮操作不缩放"
echo ""
echo "3. 边界条件："
echo "   a. 缩窄窗口至页签栏几乎无空白 → 确认仍可拖窗"
echo "   b. 切换侧栏显示/隐藏 → 确认空白区位置正确更新"
echo "   c. 进入/退出全屏 → 确认 chrome 行为正确"
echo ""
echo "=== Rust 测试 ==="
cargo test --manifest-path "$PROJECT_ROOT/Cargo.toml" 2>&1 | tail -5
echo ""
echo "验收完成。请将结果记录到 verification.md。"
