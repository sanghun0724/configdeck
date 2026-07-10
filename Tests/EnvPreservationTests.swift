import XCTest
@testable import ClaudeConfigDashboard

/// Untouched env values must keep their original JSON type on save —
/// only entries the user actually edited become strings.
@MainActor
final class EnvPreservationTests: XCTestCase {
    var home: URL!
    var settingsFile: URL!

    override func setUp() async throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "envtest-\(UUID().uuidString)")
        let claude = home.appending(path: ".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        settingsFile = claude.appending(path: "settings.json")
        let json = """
        {"env": {"DEBUG": true, "PORT": 3000, "NAME": "old"}}
        """
        try Data(json.utf8).write(to: settingsFile)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testUntouchedEnvKeepsJSONTypes() throws {
        let store = SettingsStore(home: home)
        // Edit only NAME — DEBUG/PORT stay untouched.
        if let index = store.envVars.firstIndex(where: { $0.key == "NAME" }) {
            store.envVars[index].value = "new"
        } else {
            XCTFail("NAME env var not loaded")
        }
        store.save()
        XCTAssertFalse(store.isError, store.statusMessage ?? "")

        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsFile)) as? [String: Any]
        let env = saved?["env"] as? [String: Any]
        XCTAssertEqual(env?["DEBUG"] as? Bool, true)
        XCTAssertEqual(env?["PORT"] as? Int, 3000)
        XCTAssertEqual(env?["NAME"] as? String, "new")
    }

    func testSaveCreatesMissingSettingsFile() throws {
        try FileManager.default.removeItem(at: settingsFile)
        let store = SettingsStore(home: home)
        store.addRule("Bash(ls:*)", to: .allow)
        store.save()
        XCTAssertFalse(store.isError, store.statusMessage ?? "")

        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsFile)) as? [String: Any]
        let perms = saved?["permissions"] as? [String: Any]
        XCTAssertEqual(perms?["allow"] as? [String], ["Bash(ls:*)"])
    }
}
