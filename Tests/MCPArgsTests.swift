import XCTest
@testable import ClaudeConfigDashboard

final class MCPArgsTests: XCTestCase {
    func testRoundTripPlainArgs() {
        let args = ["-y", "@mcp/server", "--port", "3000"]
        XCTAssertEqual(MCPEdit.splitArgs(MCPEdit.joinArgs(args)), args)
    }

    func testRoundTripArgWithSpaces() {
        let args = ["-y", "@mcp/server", "/Users/me/my projects"]
        let joined = MCPEdit.joinArgs(args)
        XCTAssertEqual(joined, "-y @mcp/server \"/Users/me/my projects\"")
        XCTAssertEqual(MCPEdit.splitArgs(joined), args)
    }

    func testRoundTripEmptyArg() {
        let args = ["--flag", ""]
        XCTAssertEqual(MCPEdit.splitArgs(MCPEdit.joinArgs(args)), args)
    }

    func testSplitSingleQuotes() {
        XCTAssertEqual(MCPEdit.splitArgs("run 'a b' c"), ["run", "a b", "c"])
    }

    func testSplitCollapsesWhitespace() {
        XCTAssertEqual(MCPEdit.splitArgs("  a   b  "), ["a", "b"])
    }

    func testSplitEmptyString() {
        XCTAssertEqual(MCPEdit.splitArgs(""), [])
    }
}
