import XCTest
@testable import ClaudeConfigDashboard

final class WriteGuardTests: XCTestCase {
    var dir: URL!
    var file: URL!
    var backups: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "wgtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appending(path: "settings.json")
        backups = dir.appending(path: "backups")
        try Data("v1".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func guardian() -> WriteGuard {
        WriteGuard(fileURL: file, backupDir: backups)
    }

    /// #2 atomic write replaces content; #1 backup-first captures the prior version.
    func testCommitWritesAndBacksUp() throws {
        let g = guardian()
        let h1 = WriteGuard.hash(try Data(contentsOf: file))
        try g.commit(Data("v2".utf8), expectedHash: h1)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "v2")
        XCTAssertEqual(g.backups().count, 1)
        let backupData = try Data(contentsOf: g.backups()[0])
        XCTAssertEqual(String(decoding: backupData, as: UTF8.self), "v1")
    }

    /// #5 stale-guard: a wrong expected hash must reject the write and leave the file intact.
    func testStaleGuardRejects() throws {
        let g = guardian()
        XCTAssertThrowsError(try g.commit(Data("v2".utf8), expectedHash: "deadbeef")) { error in
            XCTAssertEqual(error as? WriteGuardError, .staleFile)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "v1")
        XCTAssertTrue(g.backups().isEmpty)
    }

    /// Two same-named files (e.g. many SKILL.md) must not share or cross-restore backups.
    func testBackupsIsolatedPerFile() throws {
        let subdir = dir.appending(path: "sub")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let fileB = subdir.appending(path: "settings.json")   // same name as `file`
        try Data("b1".utf8).write(to: fileB)

        let gA = WriteGuard(fileURL: file, backupDir: backups)
        let gB = WriteGuard(fileURL: fileB, backupDir: backups)
        try gA.commit(Data("a2".utf8), expectedHash: WriteGuard.hash(Data("v1".utf8)))
        try gB.commit(Data("b2".utf8), expectedHash: WriteGuard.hash(Data("b1".utf8)))

        XCTAssertEqual(gA.backups().count, 1)
        XCTAssertEqual(gB.backups().count, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: gA.backups()[0]), as: UTF8.self), "v1")
        XCTAssertEqual(String(decoding: try Data(contentsOf: gB.backups()[0]), as: UTF8.self), "b1")
    }

    /// Delete backs up first, so the removal is recoverable.
    func testDeleteWithBackup() throws {
        let g = guardian()
        try g.deleteWithBackup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(g.backups().count, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: g.backups()[0]), as: UTF8.self), "v1")
    }

    /// Missing file: commit creates it (fresh install bootstrap / deleted-while-editing recovery).
    func testCommitCreatesMissingFile() throws {
        let g = guardian()
        try FileManager.default.removeItem(at: file)
        try g.commit(Data("v2".utf8), expectedHash: "whatever")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "v2")
        XCTAssertTrue(g.backups().isEmpty)   // nothing existed to back up
    }

    /// #7 restore: latest backup content is written back.
    func testRestoreLatest() throws {
        let g = guardian()
        let h1 = WriteGuard.hash(try Data(contentsOf: file))
        try g.commit(Data("v2".utf8), expectedHash: h1)   // backup holds "v1", file now "v2"

        let h2 = WriteGuard.hash(try Data(contentsOf: file))
        try g.restoreLatest(expectedHash: h2)             // restore newest backup ("v1")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "v1")
    }
}
