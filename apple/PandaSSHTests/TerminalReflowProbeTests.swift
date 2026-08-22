import XCTest
import SwiftTerm

#if os(macOS)
@testable import PandaSSH_macOS

/// 终端 resize 探针：模拟「侧栏显隐动画期间终端宽度逐帧变化 + bash SIGWINCH 重绘」，
/// 观测 SwiftTerm buffer 的 yDisp 与光标行 y（public API），验证「终端内容沉底」的成因。
///
/// 指标说明：初始 feed prompt 后光标 y=0（顶部行）。
/// 若一系列 resize 后光标 y 明显增大（上方出现空行），即复现「内容沉底」。
@MainActor
final class TerminalReflowProbeTests: XCTestCase {

    private let promptText = "[lwq@weidoc ~]$ "

    /// readline 收到 SIGWINCH 后的典型重绘序列：回车 + 清行 + 重画 prompt
    private var redrawSequence: [UInt8] {
        Array("\r\u{1b}[K\(promptText)".utf8)
    }

    private func dumpState(_ tv: PandaTerminalView, _ label: String) -> (yDisp: Int, y: Int) {
        guard let terminal = tv.terminal else {
            print("PROBE [\(label)] terminal=nil")
            return (-1, -1)
        }
        let buffer = terminal.buffer
        print("PROBE [\(label)] cols=\(terminal.cols) rows=\(terminal.rows) " +
              "yDisp=\(buffer.yDisp) cursorY=\(buffer.y) cursorX=\(buffer.x) trimmed=\(buffer.totalLinesTrimmed)")
        return (buffer.yDisp, buffer.y)
    }

    /// 场景 A：初始大宽度下 shell 就绪，随后宽度逐帧收窄再恢复（模拟侧栏显示/隐藏动画）。
    func testProbeWidthAnimationCausesSink() {
        let tv = PandaTerminalView(frame: .zero, font: nil)
        // 模拟 SwiftUI 布局完成后的稳定帧（侧栏隐藏时 detail 宽 882）
        tv.setFrameSize(NSSize(width: 882, height: 563))
        tv.feed(byteArray: Array(promptText.utf8)[...])
        let initial = dumpState(tv, "initial 882pt")
        XCTAssertEqual(initial.y, 0, "初始光标应在顶部行")

        // 侧栏显示动画：882 → 624，约 10 帧；每帧后 bash 重绘 prompt
        for width in stride(from: 882.0, through: 624.0, by: -26.0) {
            tv.setFrameSize(NSSize(width: width, height: 563))
            tv.feed(byteArray: redrawSequence[...])
        }
        let narrowed = dumpState(tv, "narrowed 624pt")

        // 侧栏再隐藏：624 → 882
        for width in stride(from: 624.0, through: 882.0, by: 26.0) {
            tv.setFrameSize(NSSize(width: width, height: 563))
            tv.feed(byteArray: redrawSequence[...])
        }
        let restored = dumpState(tv, "restored 882pt")

        XCTAssertEqual(narrowed.y, 0, "收窄后光标行下移（内容沉底）: y=\(narrowed.y)")
        XCTAssertEqual(restored.y, 0, "恢复后光标行下移（内容沉底）: y=\(restored.y)")
    }

    /// 场景 B：高度先被压扁再恢复（页签栏高度抖动把终端压到 1 行再高回来）。
    func testProbeHeightSquashCausesSink() {
        let tv = PandaTerminalView(frame: .zero, font: nil)
        tv.setFrameSize(NSSize(width: 882, height: 563))
        tv.feed(byteArray: Array(promptText.utf8)[...])
        _ = dumpState(tv, "initial 563h")

        // 高度被压到一行再恢复
        tv.setFrameSize(NSSize(width: 882, height: 20))
        tv.feed(byteArray: redrawSequence[...])
        let squashed = dumpState(tv, "squashed 20h")

        tv.setFrameSize(NSSize(width: 882, height: 563))
        tv.feed(byteArray: redrawSequence[...])
        let restored = dumpState(tv, "restored 563h")

        XCTAssertEqual(restored.y, 0, "高度压扁再恢复后光标行下移（内容沉底）: y=\(restored.y)（压扁时 y=\(squashed.y)）")
    }
}
#endif
