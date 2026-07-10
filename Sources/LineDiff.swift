import Foundation

/// Minimal line-based diff (LCS) for the apply-fix preview. Not a general diff —
/// just enough to show what Claude's fix changes before it's written.
enum LineDiff {
    enum Kind { case same, removed, added }
    struct Line: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
        let text: String
        static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.kind == rhs.kind && lhs.text == rhs.text
        }
    }

    /// Unified sequence of kept/removed/added lines. Inputs are capped by the
    /// caller (huge files get a summary instead of a diff).
    static func diff(_ old: String, _ new: String) -> [Line] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        // LCS table — fine for config-file sizes; callers cap at a few thousand lines.
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append(Line(kind: .same, text: a[i])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(Line(kind: .removed, text: a[i])); i += 1
            } else {
                result.append(Line(kind: .added, text: b[j])); j += 1
            }
        }
        while i < a.count { result.append(Line(kind: .removed, text: a[i])); i += 1 }
        while j < b.count { result.append(Line(kind: .added, text: b[j])); j += 1 }
        return result
    }

    /// Collapse long unchanged runs to keep the preview readable: keep `context`
    /// lines around every change, replace the middle of longer runs with a gap marker.
    static func collapse(_ lines: [Line], context: Int = 3) -> [(line: Line?, gap: Int)] {
        var out: [(Line?, Int)] = []
        var run: [Line] = []
        func flushRun(isEnd: Bool) {
            let keepHead = out.isEmpty ? 0 : context   // no context needed before first change
            let keepTail = isEnd ? 0 : context
            if run.count > keepHead + keepTail + 1 {
                run.prefix(keepHead).forEach { out.append(($0, 0)) }
                out.append((nil, run.count - keepHead - keepTail))
                run.suffix(keepTail).forEach { out.append(($0, 0)) }
            } else {
                run.forEach { out.append(($0, 0)) }
            }
            run = []
        }
        for line in lines {
            if line.kind == .same {
                run.append(line)
            } else {
                flushRun(isEnd: false)
                out.append((line, 0))
            }
        }
        flushRun(isEnd: true)
        return out
    }
}
