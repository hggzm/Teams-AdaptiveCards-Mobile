import Testing
import Foundation
@testable import SwiftOAuthCore

@Suite struct TokenStoreTests {
    private func tempStore() -> TokenStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftoauth-tests-\(UUID().uuidString)", isDirectory: true)
        return TokenStore(directory: dir)
    }

    private func token(_ provider: String, access: String = "at") -> TokenSet {
        TokenSet(accessToken: access, tokenType: "bearer", refreshToken: "rt",
                 scope: "read", expiresIn: 3600, providerID: provider)
    }

    @Test func loadAllEmptyWhenNoFile() throws {
        #expect(try tempStore().loadAll().isEmpty)
    }

    @Test func saveThenLoadRoundTrip() throws {
        let store = tempStore()
        let original = token("github", access: "gho_x")
        try store.save(original)
        #expect(try store.load(providerID: "github") == original)
    }

    @Test func multipleProvidersCoexist() throws {
        let store = tempStore()
        try store.save(token("github", access: "gh"))
        try store.save(token("discord", access: "dc"))
        #expect(try store.load(providerID: "github")?.accessToken == "gh")
        #expect(try store.load(providerID: "discord")?.accessToken == "dc")
        #expect(try store.loadAll().count == 2)
    }

    @Test func saveOverwritesSameProvider() throws {
        let store = tempStore()
        try store.save(token("github", access: "old"))
        try store.save(token("github", access: "new"))
        #expect(try store.load(providerID: "github")?.accessToken == "new")
        #expect(try store.loadAll().count == 1)
    }

    @Test func deleteRemovesOnlyThatProvider() throws {
        let store = tempStore()
        try store.save(token("github"))
        try store.save(token("discord"))
        try store.delete(providerID: "github")
        #expect(try store.load(providerID: "github") == nil)
        #expect(try store.load(providerID: "discord") != nil)
    }

    @Test func loadMissingProviderReturnsNil() throws {
        let store = tempStore()
        try store.save(token("github"))
        #expect(try store.load(providerID: "discord") == nil)
    }

    #if !os(Windows)
    @Test func fileIsOwnerOnly0600() throws {
        // POSIX-only: Windows relies on %USERPROFILE% ACL inheritance instead.
        let store = tempStore()
        try store.save(token("github"))
        let path = store.directory.appendingPathComponent("tokens.json").path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }
    #endif
}
