import XCTest
@testable import ConfigDeck

final class SessionTranscriptParserTests: XCTestCase {

    func testUserStringContentBecomesUserTurn() throws {
        let raw = """
        {"type":"user","message":{"role":"user","content":"fix the bug"},"timestamp":"2026-07-05T08:55:31.734Z","isSidechain":false,"cwd":"/tmp/proj","gitBranch":"main"}
        """
        let transcript = SessionTranscriptParser.parse(raw)
        XCTAssertEqual(transcript.turns.count, 1)
        guard case let .user(text) = transcript.turns[0].kind else { return XCTFail("expected user turn") }
        XCTAssertEqual(text, "fix the bug")
        // Real timestamps always carry fractional seconds — must parse.
        XCTAssertNotNil(transcript.turns[0].timestamp)
        XCTAssertEqual(transcript.cwd, "/tmp/proj")
        XCTAssertEqual(transcript.gitBranch, "main")
    }

    func testUserArrayContentBecomesToolResult() throws {
        let raw = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok done"}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"part one"},{"type":"tool_reference","tool_name":"Bash"},{"type":"text","text":"part two"}],"is_error":true}]}}
        """
        let transcript = SessionTranscriptParser.parse(raw)
        XCTAssertEqual(transcript.turns.count, 2)
        guard case let .toolResult(text1, isError1) = transcript.turns[0].kind else { return XCTFail("expected tool result") }
        XCTAssertEqual(text1, "ok done")
        XCTAssertFalse(isError1)
        guard case let .toolResult(text2, isError2) = transcript.turns[1].kind else { return XCTFail("expected tool result") }
        XCTAssertEqual(text2, "part one\npart two")   // tool_reference block skipped
        XCTAssertTrue(isError2)
    }

    func testAssistantBlocksKeepOrderAndKeys() throws {
        let raw = """
        {"type":"assistant","message":{"model":"claude-fable-5","role":"assistant","content":[{"type":"thinking","thinking":"pondering","signature":"c2ln"},{"type":"text","text":"here is the fix"},{"type":"tool_use","name":"Bash","input":{"command":"git status","description":"check"}},{"type":"tool_use","name":"Read","input":{"file_path":"/a/b.swift"}},{"type":"tool_use","name":"Grep","input":{"pattern":"foo"}}]}}
        """
        let transcript = SessionTranscriptParser.parse(raw)
        XCTAssertEqual(transcript.model, "claude-fable-5")
        XCTAssertEqual(transcript.turns.count, 5)
        guard case let .thinking(thought) = transcript.turns[0].kind else { return XCTFail("expected thinking") }
        XCTAssertEqual(thought, "pondering")   // payload lives under "thinking", not "text"
        guard case let .assistantText(markdown) = transcript.turns[1].kind else { return XCTFail("expected text") }
        XCTAssertEqual(markdown, "here is the fix")
        guard case let .toolUse(name1, summary1) = transcript.turns[2].kind else { return XCTFail("expected tool use") }
        XCTAssertEqual(name1, "Bash")
        XCTAssertEqual(summary1, "git status")          // command wins
        guard case let .toolUse(_, summary2) = transcript.turns[3].kind else { return XCTFail("expected tool use") }
        XCTAssertEqual(summary2, "/a/b.swift")          // file_path fallback
        guard case let .toolUse(_, summary3) = transcript.turns[4].kind else { return XCTFail("expected tool use") }
        XCTAssertEqual(summary3, "foo")                 // first string value fallback
    }

    func testLastAiTitleWins() throws {
        let raw = """
        {"type":"ai-title","aiTitle":"first title","sessionId":"s"}
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"ai-title","aiTitle":"second title","sessionId":"s"}
        """
        XCTAssertEqual(SessionTranscriptParser.parse(raw).title, "second title")
    }

    func testMalformedAndUnknownLinesAreCountedNotFatal() throws {
        let raw = """
        not json at all {{{
        {"type":"some-future-event","payload":1}
        {"type":"user","message":{"role":"user","content":"still parsed"}}
        """
        let transcript = SessionTranscriptParser.parse(raw)
        XCTAssertEqual(transcript.skippedLines, 2)
        XCTAssertEqual(transcript.turns.count, 1)
    }

    func testNoiseTypesProduceNoTurnsAndNoSkipCount() throws {
        let raw = """
        {"type":"mode","mode":"normal","sessionId":"s"}
        {"type":"attachment","attachment":{},"uuid":"u"}
        {"type":"file-history-snapshot","sessionId":"s"}
        {"type":"last-prompt","leafUuid":"u","sessionId":"s"}
        {"type":"system","subtype":"hook","content":"x"}
        """
        let transcript = SessionTranscriptParser.parse(raw)
        XCTAssertTrue(transcript.turns.isEmpty)
        XCTAssertEqual(transcript.skippedLines, 0)
    }

    func testSidechainFlagPreserved() throws {
        let raw = """
        {"type":"user","message":{"role":"user","content":"subagent prompt"},"isSidechain":true}
        {"type":"user","message":{"role":"user","content":"main prompt"},"isSidechain":false}
        """
        let transcript = SessionTranscriptParser.parse(raw)
        XCTAssertTrue(transcript.turns[0].isSidechain)
        XCTAssertFalse(transcript.turns[1].isSidechain)
    }

    func testOversizedBlockIsTruncated() throws {
        let big = String(repeating: "a", count: 100_000)
        let raw = """
        {"type":"user","message":{"role":"user","content":"\(big)"}}
        """
        let transcript = SessionTranscriptParser.parse(raw)
        guard case let .user(text) = transcript.turns[0].kind else { return XCTFail("expected user turn") }
        XCTAssertTrue(text.hasSuffix("… (truncated)"))
        XCTAssertLessThan(text.count, 21_000)
    }
}

final class SessionScannerTests: XCTestCase {
    private var home: URL!
    private var projectDir: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "session-scanner-tests-\(UUID().uuidString)")
        projectDir = home.appending(path: ".claude/projects/-Users-test-my-proj")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ content: String, to name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? projectDir).appending(path: name)
        try Data(content.utf8).write(to: url)
        return url
    }

    // MARK: - title(for:)

    /// The tail window seek can land mid-way through a 3-byte Korean UTF-8 character.
    /// Three size variants shift the cut by one byte each, so at least one lands
    /// mid-character — without newline realignment that variant fails to decode.
    func testTailTitleSurvivesMultibyteSeekBoundary() throws {
        for extra in 0..<3 {
            let pad = String(repeating: "가", count: 30_000)   // 90KB — beyond the 64KB tail window
            let content = """
            {"type":"user","message":{"role":"user","content":"\(pad)"}}
            {"type":"mode","mode":"x\(String(repeating: "y", count: extra))"}
            {"type":"ai-title","aiTitle":"한글 제목 테스트","sessionId":"s"}
            """
            let url = try write(content, to: "boundary-\(extra).jsonl")
            let title = SessionScanner(home: home).title(for: url.path)
            XCTAssertEqual(title, "한글 제목 테스트", "variant \(extra)")
        }
    }

    func testTitleFallsBackToFirstUserPrompt() throws {
        let content = """
        {"type":"mode","mode":"normal"}
        {"type":"user","message":{"role":"user","content":"<local-command-caveat>skip me</local-command-caveat>"}}
        {"type":"user","message":{"role":"user","content":"subagent"},"isSidechain":true}
        {"type":"user","message":{"role":"user","content":"real prompt line one\\nsecond line"}}
        """
        let url = try write(content, to: "no-title.jsonl")
        XCTAssertEqual(SessionScanner(home: home).title(for: url.path), "real prompt line one")
    }

    func testTitleNilWhenNothingUsable() throws {
        let url = try write("{\"type\":\"mode\",\"mode\":\"normal\"}", to: "empty-ish.jsonl")
        XCTAssertNil(SessionScanner(home: home).title(for: url.path))
    }

    // MARK: - scan()

    func testScanListsOnlyTopLevelJsonlAndRecoversDisplayPath() throws {
        let older = try write(
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"},\"cwd\":\"/Users/test/my.proj\"}",
            to: "aaa.jsonl"
        )
        _ = try write(
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"},\"cwd\":\"/Users/test/my.proj\"}",
            to: "bbb.jsonl"
        )
        _ = try write("{}", to: "sessions-index.json")
        let subdir = projectDir.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        _ = try write("{}", to: "nested.jsonl", in: subdir)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path
        )

        let projects = SessionScanner(home: home).scan()
        XCTAssertEqual(projects.count, 1)
        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(project.displayPath, "/Users/test/my.proj")   // lossy dir name recovered from cwd
        // sessionId comparison keeps this agnostic to /var vs /private/var temp symlinks.
        XCTAssertEqual(project.sessions.map(\.sessionId), ["bbb", "aaa"])   // newest first
    }

    func testScanFallsBackToDirNameWithoutCwd() throws {
        _ = try write("{\"type\":\"mode\",\"mode\":\"normal\"}", to: "a.jsonl")
        let projects = SessionScanner(home: home).scan()
        XCTAssertEqual(projects.first?.displayPath, "-Users-test-my-proj")
    }
}

final class SessionContentSearcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "session-search-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMatchesConversationTextOnly() throws {
        // "needle" appears in assistant text (hit), in a signature and a tool name
        // (both excluded), and in a second file not at all.
        let matching = dir.appending(path: "match.jsonl")
        try Data("""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"the needle is right here in prose"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"thinking about the needle too","signature":"bmVlZGxl"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"needle-tool","input":{"command":"needle"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"needle in a tool result"}]}}
        """.utf8).write(to: matching)
        let other = dir.appending(path: "other.jsonl")
        try Data("""
        {"type":"user","message":{"role":"user","content":"nothing to see"}}
        """.utf8).write(to: other)

        var hits: [SessionSearchHit] = []
        var scanned = 0
        SessionContentSearcher().search(
            query: "NEEDLE",
            in: [matching.path, other.path],
            onProgress: { scanned = $0 },
            onHit: { hits.append($0) }
        )

        XCTAssertEqual(scanned, 2)
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.path, matching.path)
        // text + thinking + tool_result match; tool_use line is excluded entirely.
        XCTAssertEqual(hit.matchCount, 3)
        XCTAssertTrue(hit.snippet.localizedCaseInsensitiveContains("needle"))
    }

    func testCancellationStopsAtFileBoundary() throws {
        let a = dir.appending(path: "a.jsonl")
        try Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"needle\"}}".utf8).write(to: a)
        var hits = 0
        SessionContentSearcher().search(
            query: "needle",
            in: [a.path, a.path],
            isCancelled: { true },
            onHit: { _ in hits += 1 }
        )
        XCTAssertEqual(hits, 0)
    }
}
