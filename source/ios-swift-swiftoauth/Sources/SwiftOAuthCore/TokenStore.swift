// Token store — persists TokenSets to ~/.swiftoauth/tokens.json.
//
// Security posture:
//  - The file is written with mode 0600 on POSIX platforms (owner read/write
//    only). On Windows, POSIX mode bits do not apply; files created under
//    %USERPROFILE%\.swiftoauth inherit that profile's ACL, which is already
//    restricted to the user, SYSTEM, and Administrators. This is the documented
//    Windows caveat — there is no world-readable exposure either way.
//  - Tokens are NEVER logged. Callers decide whether to display them.
//  - Writes go through a temp file + move so a crash cannot leave a truncated
//    token file. (We avoid FileManager.replaceItemAt, which is unimplemented on
//    Windows swift-corelibs-foundation.)
import Foundation

/// On-disk store for OAuth tokens, keyed by provider id.
public struct TokenStore: Sendable {
    /// Directory holding `tokens.json` (default `~/.swiftoauth`).
    public let directory: URL
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else if let home = ProcessInfo.processInfo.environment["SWIFTOAUTH_HOME"], !home.isEmpty {
            // Relocate the whole config dir, e.g. for tests or an isolated profile.
            dir = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".swiftoauth", isDirectory: true)
        } else {
            dir = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".swiftoauth", isDirectory: true)
        }
        self.directory = dir
        self.fileURL = dir.appendingPathComponent("tokens.json")
    }

    /// All stored tokens, keyed by provider id. Empty if the file is absent.
    public func loadAll() throws -> [String: TokenSet] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [:] }
        return try JSONDecoder().decode([String: TokenSet].self, from: data)
    }

    /// Load the token for one provider, or `nil` if none is stored.
    public func load(providerID: String) throws -> TokenSet? {
        try loadAll()[providerID]
    }

    /// Persist (or replace) the token for its provider.
    public func save(_ token: TokenSet) throws {
        var all = (try? loadAll()) ?? [:]
        all[token.providerID] = token
        try writeAll(all)
    }

    /// Remove the token for a provider. No-op if none is stored.
    public func delete(providerID: String) throws {
        var all = (try? loadAll()) ?? [:]
        guard all.removeValue(forKey: providerID) != nil else { return }
        try writeAll(all)
    }

    // MARK: - Private

    private func writeAll(_ all: [String: TokenSet]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        restrictPermissions(on: directory, isDirectory: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(all)

        let tmp = directory.appendingPathComponent(
            "tokens.json.tmp-\(ProcessInfo.processInfo.processIdentifier)"
        )
        try? FileManager.default.removeItem(at: tmp)
        try data.write(to: tmp)
        restrictPermissions(on: tmp, isDirectory: false)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tmp, to: fileURL)
        restrictPermissions(on: fileURL, isDirectory: false)
    }

    /// Apply owner-only permissions where the platform supports POSIX modes.
    private func restrictPermissions(on url: URL, isDirectory: Bool) {
        #if !os(Windows)
        let mode: NSNumber = isDirectory ? 0o700 : 0o600
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        #endif
        // Windows: ACL inheritance from %USERPROFILE% (see file header).
    }
}
