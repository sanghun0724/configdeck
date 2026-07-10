import XCTest
@testable import ClaudeConfigDashboard

final class SettingsSerializerTests: XCTestCase {

    /// Defense #3: editing permissions must not drop any other key.
    func testPreserveUnknownKeys() throws {
        let root: [String: Any] = [
            "language": "korean",
            "includeCoAuthoredBy": false,
            "statusLine": ["type": "command"],
            "permissions": ["allow": ["A"], "deny": ["D"], "defaultMode": "acceptEdits"]
        ]
        let merged = SettingsSerializer.apply(root: root, allow: ["A", "B"], ask: ["K"], deny: [])

        XCTAssertEqual(merged["language"] as? String, "korean")
        XCTAssertEqual(merged["includeCoAuthoredBy"] as? Bool, false)
        XCTAssertNotNil(merged["statusLine"])

        let perms = try XCTUnwrap(merged["permissions"] as? [String: Any])
        XCTAssertEqual(perms["allow"] as? [String], ["A", "B"])
        XCTAssertEqual(perms["ask"] as? [String], ["K"])
        XCTAssertEqual(perms["deny"] as? [String], [])
        // unknown sub-key inside permissions also preserved
        XCTAssertEqual(perms["defaultMode"] as? String, "acceptEdits")
    }

    /// Deterministic output → clean git diffs across repeated saves.
    func testSerializeDeterministicAndValid() throws {
        let dict: [String: Any] = ["b": 1, "a": ["z", "y"], "permissions": ["allow": ["X"]]]
        let d1 = try SettingsSerializer.serialize(dict)
        let d2 = try SettingsSerializer.serialize(dict)
        XCTAssertEqual(d1, d2)

        let parsed = try JSONSerialization.jsonObject(with: d1) as? [String: Any]
        XCTAssertEqual(parsed?["b"] as? Int, 1)
    }

    /// Full apply → serialize → parse round trip preserves everything.
    func testRoundTrip() throws {
        let root: [String: Any] = ["x": "keep", "permissions": ["allow": ["old"], "extra": 5]]
        let merged = SettingsSerializer.apply(root: root, allow: ["new"], ask: [], deny: [])
        let data = try SettingsSerializer.serialize(merged)
        let back = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(back["x"] as? String, "keep")
        let perms = try XCTUnwrap(back["permissions"] as? [String: Any])
        XCTAssertEqual(perms["allow"] as? [String], ["new"])
        XCTAssertEqual(perms["extra"] as? Int, 5)
    }
}
