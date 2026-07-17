import Foundation

/// Checks GitHub for a newer release than the running app. Mirrors install.sh's
/// trick: the /releases/latest redirect carries the tag in its final URL, so no
/// GitHub API call and no rate limits. Fails silently — an offline launch just
/// shows no banner.
enum UpdateChecker {
    static let repo = "sanghun0724/configdeck"
    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | sh"

    /// Returns the latest release tag (e.g. "v0.1.3") if it is newer than the
    /// running app's version, nil otherwise.
    static func checkForUpdate() async -> String? {
        guard
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let tag = await fetchLatestTag(),
            isNewer(latest: tag, current: current)
        else { return nil }
        return tag
    }

    private static func fetchLatestTag() async -> String? {
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let final = response.url,
              final.pathComponents.contains("tag")   // no releases yet → no /tag/ in the URL
        else { return nil }
        return final.lastPathComponent
    }

    /// Numeric component comparison ("v" prefix ignored), so "0.1.10" > "0.1.2".
    static func isNewer(latest: String, current: String) -> Bool {
        let l = latest.hasPrefix("v") ? String(latest.dropFirst()) : latest
        let c = current.hasPrefix("v") ? String(current.dropFirst()) : current
        return l.compare(c, options: .numeric) == .orderedDescending
    }
}
