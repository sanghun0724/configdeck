import XCTest
@testable import ClaudeConfigDashboard

final class FrontmatterParserTests: XCTestCase {

    func testBasicKeyValue() throws {
        let content = """
        ---
        name: my-skill
        description: does things
        ---
        Body text.
        """
        let fm = FrontmatterParser.parse(content)
        XCTAssertEqual(fm["name"], "my-skill")
        XCTAssertEqual(fm["description"], "does things")
    }

    func testQuotedValuesAreStripped() throws {
        let content = """
        ---
        name: "quoted-name"
        description: 'single quoted'
        ---
        """
        let fm = FrontmatterParser.parse(content)
        XCTAssertEqual(fm["name"], "quoted-name")
        XCTAssertEqual(fm["description"], "single quoted")
    }

    func testNoFrontmatterReturnsEmpty() throws {
        let content = """
        # Just a heading
        No frontmatter here.
        """
        let fm = FrontmatterParser.parse(content)
        XCTAssertTrue(fm.isEmpty)
    }

    /// Comma-separated values (e.g. `allowed-tools`) must survive as a single raw string;
    /// splitting/trimming that list is ConfigScanner's job, not the parser's.
    func testCommaSeparatedValueKeptAsRawString() throws {
        let content = """
        ---
        allowed-tools: Read, Grep, Bash
        ---
        """
        let fm = FrontmatterParser.parse(content)
        XCTAssertEqual(fm["allowed-tools"], "Read, Grep, Bash")
    }
}
