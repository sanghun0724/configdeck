import XCTest
@testable import ClaudeConfigDashboard

final class LineDiffTests: XCTestCase {
    private func render(_ lines: [LineDiff.Line]) -> [String] {
        lines.map {
            switch $0.kind {
            case .same: return " \($0.text)"
            case .removed: return "-\($0.text)"
            case .added: return "+\($0.text)"
            }
        }
    }

    func testIdenticalTextsHaveNoChanges() {
        let lines = LineDiff.diff("a\nb", "a\nb")
        XCTAssertTrue(lines.allSatisfy { $0.kind == .same })
    }

    func testSingleLineReplacement() {
        let lines = LineDiff.diff("a\nb\nc", "a\nX\nc")
        XCTAssertEqual(render(lines), [" a", "-b", "+X", " c"])
    }

    func testAdditionAndRemovalAtEnds() {
        XCTAssertEqual(render(LineDiff.diff("a\nb", "b")), ["-a", " b"])
        XCTAssertEqual(render(LineDiff.diff("a", "a\nz")), [" a", "+z"])
    }

    func testCollapseKeepsContextAroundChanges() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "10", with: "TEN")
        let collapsed = LineDiff.collapse(LineDiff.diff(old, new), context: 2)
        // One gap before (lines 1-7) and one after (lines 13-20); context 8,9 / 11,12 kept.
        let gaps = collapsed.filter { $0.line == nil }
        XCTAssertEqual(gaps.count, 2)
        XCTAssertTrue(collapsed.contains { $0.line?.text == "8" })
        XCTAssertTrue(collapsed.contains { $0.line?.kind == .removed && $0.line?.text == "10" })
        XCTAssertTrue(collapsed.contains { $0.line?.kind == .added && $0.line?.text == "TEN" })
        XCTAssertFalse(collapsed.contains { $0.line?.text == "3" })   // swallowed by gap
    }
}
