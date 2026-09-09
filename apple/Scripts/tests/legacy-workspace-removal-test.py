#!/usr/bin/env python3
"""退役契约：生产 UI 不得重新引入旧装配或失效偏好。"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]

class LegacyWorkspaceRemovalTests(unittest.TestCase):
    def test旧装配与组件不可达(self):
        retired = ("WorkspaceChromeStrategy", "WorkspaceChromeRoute", "WorkspaceTabBar",
                   "WorkspaceTabButton", "WorkspaceTabItemView", "HorizontalWheelScrollView",
                   "TabBarScrollController", "TabBarScrollMetrics", "WorkspaceChromePolicy",
                   "WorkspaceTabPresentationMetrics", "isUnifiedWorkspaceChrome")
        for path in (ROOT / "apple/PandaSSH").rglob("*.swift"):
            source = path.read_text()
            for symbol in retired:
                with self.subTest(file=str(path.relative_to(ROOT)), symbol=symbol):
                    self.assertNotIn(symbol, source)

    def test历史或非法溢出偏好均不再参与装配(self):
        for name in ("Workspace/WorkspaceStore.swift", "SettingsView.swift"):
            source = (ROOT / "apple/PandaSSH" / name).read_text()
            self.assertNotIn("tabBarOverflowMode", source)
            self.assertNotIn("TabBarOverflowMode", source)

    def test保留双端统一栏及关闭确认入口(self):
        source = (ROOT / "apple/PandaSSH/Workspace/WorkspaceView.swift").read_text()
        for symbol in ("UnifiedWorkspaceChrome(", "UnifiedWorkspaceTabStrip(",
                       "MacOSUnifiedSplitHost(", "confirmClose()", "confirmBatchClose()"):
            self.assertIn(symbol, source)

if __name__ == "__main__":
    unittest.main()
