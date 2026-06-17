import Foundation
import Vapor

/// Phase 40: Organizations + teams.
///
/// On-disk shape (one envelope, server-wide):
///
///     <root>/.giteax/orgs.json
///       {
///         "version": 1,
///         "orgs": [
///           {
///             name, description, createdBy, createdAt,
///             owners: ["alice", ...],
///             teams: [
///               {
///                 name, description,
///                 permission: "read"|"write"|"admin",
///                 members: ["bob", ...],
///                 repos:   ["proj-a", "proj-b"] // or ["*"] for all org repos
///               }
///             ]
///           }
///         ]
///       }
///
/// Org names share the user namespace: registering "acme" as an org
/// reserves it from `UserStore` and vice versa. Repos owned by an org
/// live at `<root>/<orgName>/<repoName>.git` exactly like user repos;
/// the AccessController consults `OrgStore` to derive permissions when
/// the path's owner segment matches a registered org.
///
/// Owners of an org are admin on every repo in the org. Team members
/// receive the team's permission on the repos listed in `repos`
/// (with the sentinel `"*"` granting access to every repo in the org).
actor OrgStore {

    struct Team: Sendable, Codable, Equatable {
        var name: String
        var description: String
        var permission: RepoMetaStore.Permission
        var members: [String]
        var repos: [String]
    }

    struct Org: Sendable, Codable {
        let name: String
        var description: String
        let createdBy: String
        let createdAt: Date
        var owners: [String]
        var teams: [Team]
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var orgs: [Org]
    }

    enum StoreError: Error, AbortError {
        case orgNotFound(String)
        case teamNotFound(org: String, team: String)
        case duplicateOrg(String)
        case duplicateTeam(org: String, team: String)
        case lastOwner(String)
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .orgNotFound, .teamNotFound: .notFound
            case .duplicateOrg, .duplicateTeam, .lastOwner: .conflict
            case .invalidInput: .badRequest
            case .ioFailed, .badEnvelope: .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .orgNotFound(let n):    "no organization '\(n)'"
            case .teamNotFound(let o, let t): "no team '\(t)' in organization '\(o)'"
            case .duplicateOrg(let n):   "organization '\(n)' already exists (or name collides with a user)"
            case .duplicateTeam(let o, let t): "team '\(t)' already exists in organization '\(o)'"
            case .lastOwner(let o):      "cannot remove the last owner of organization '\(o)'"
            case .invalidInput(let d):   "invalid org input: \(d)"
            case .ioFailed(let d):       "org-store I/O failed: \(d)"
            case .badEnvelope(let d):    "org-store JSON malformed: \(d)"
            }
        }
    }

    let root: URL
    private var envelope: Envelope?

    init(root: URL) throws {
        let dir = root.appendingPathComponent(".giteax", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.root = root
    }

    // MARK: - Read

    func list() throws -> [Org] {
        let env = try loadOrInit()
        return env.orgs.sorted { $0.name < $1.name }
    }

    func get(_ name: String) throws -> Org? {
        let env = try loadOrInit()
        return env.orgs.first { $0.name == name }
    }

    /// True iff `name` is a registered organization.
    func isOrg(_ name: String) throws -> Bool {
        let env = try loadOrInit()
        return env.orgs.contains { $0.name == name }
    }

    /// Effective permission for `userName` on `<orgName>/<repoName>`:
    ///   - org owner: .admin
    ///   - max permission across teams that include the user AND list
    ///     either `repoName` or `"*"` in their repos
    ///   - nil otherwise
    func effectivePermission(
        org orgName: String, repo repoName: String, user userName: String
    ) throws -> RepoMetaStore.Permission? {
        let env = try loadOrInit()
        guard let org = env.orgs.first(where: { $0.name == orgName }) else {
            return nil
        }
        if org.owners.contains(userName) { return .admin }
        var best: RepoMetaStore.Permission? = nil
        for team in org.teams where team.members.contains(userName) {
            let repoMatches = team.repos.contains("*") || team.repos.contains(repoName)
            guard repoMatches else { continue }
            if best == nil || team.permission > best! {
                best = team.permission
            }
        }
        return best
    }

    // MARK: - Org mutations

    @discardableResult
    func createOrg(name: String, description: String, createdBy: String, initialOwners: [String]) throws -> Org {
        try validateName(name)
        var env = try loadOrInit()
        if env.orgs.contains(where: { $0.name == name }) {
            throw StoreError.duplicateOrg(name)
        }
        var owners = Array(Set(initialOwners.filter { !$0.isEmpty })).sorted()
        if owners.isEmpty {
            // Fallback: the requester becomes the sole owner so the org
            // is never created without one.
            owners = [createdBy]
        }
        let ownersTeam = Team(
            name: "owners",
            description: "Organization owners (admin on every repo).",
            permission: .admin,
            members: owners,
            repos: ["*"]
        )
        let org = Org(
            name: name,
            description: description,
            createdBy: createdBy,
            createdAt: Date(),
            owners: owners,
            teams: [ownersTeam]
        )
        env.orgs.append(org)
        try persist(env)
        return org
    }

    @discardableResult
    func deleteOrg(name: String) throws -> Bool {
        var env = try loadOrInit()
        let before = env.orgs.count
        env.orgs.removeAll { $0.name == name }
        guard env.orgs.count != before else { return false }
        try persist(env)
        return true
    }

    @discardableResult
    func setDescription(org orgName: String, description: String) throws -> Org {
        var env = try loadOrInit()
        guard let idx = env.orgs.firstIndex(where: { $0.name == orgName }) else {
            throw StoreError.orgNotFound(orgName)
        }
        env.orgs[idx].description = description
        try persist(env)
        return env.orgs[idx]
    }

    @discardableResult
    func addOwner(org orgName: String, user: String) throws -> Org {
        try validateMemberName(user)
        var env = try loadOrInit()
        guard let idx = env.orgs.firstIndex(where: { $0.name == orgName }) else {
            throw StoreError.orgNotFound(orgName)
        }
        if !env.orgs[idx].owners.contains(user) {
            env.orgs[idx].owners.append(user)
            env.orgs[idx].owners.sort()
        }
        // Owners are also members of the "owners" team.
        if let tIdx = env.orgs[idx].teams.firstIndex(where: { $0.name == "owners" }),
           !env.orgs[idx].teams[tIdx].members.contains(user) {
            env.orgs[idx].teams[tIdx].members.append(user)
            env.orgs[idx].teams[tIdx].members.sort()
        }
        try persist(env)
        return env.orgs[idx]
    }

    @discardableResult
    func removeOwner(org orgName: String, user: String) throws -> Org {
        var env = try loadOrInit()
        guard let idx = env.orgs.firstIndex(where: { $0.name == orgName }) else {
            throw StoreError.orgNotFound(orgName)
        }
        guard env.orgs[idx].owners.contains(user) else { return env.orgs[idx] }
        if env.orgs[idx].owners.count <= 1 {
            throw StoreError.lastOwner(orgName)
        }
        env.orgs[idx].owners.removeAll { $0 == user }
        if let tIdx = env.orgs[idx].teams.firstIndex(where: { $0.name == "owners" }) {
            env.orgs[idx].teams[tIdx].members.removeAll { $0 == user }
        }
        try persist(env)
        return env.orgs[idx]
    }

    // MARK: - Team mutations

    @discardableResult
    func createTeam(
        org orgName: String,
        name: String, description: String,
        permission: RepoMetaStore.Permission,
        members: [String], repos: [String]
    ) throws -> Team {
        try validateName(name)
        var env = try loadOrInit()
        guard let idx = env.orgs.firstIndex(where: { $0.name == orgName }) else {
            throw StoreError.orgNotFound(orgName)
        }
        if env.orgs[idx].teams.contains(where: { $0.name == name }) {
            throw StoreError.duplicateTeam(org: orgName, team: name)
        }
        let cleanMembers = Array(Set(members.filter { !$0.isEmpty })).sorted()
        let cleanRepos = Array(Set(repos.filter { !$0.isEmpty })).sorted()
        let team = Team(
            name: name, description: description,
            permission: permission,
            members: cleanMembers, repos: cleanRepos
        )
        env.orgs[idx].teams.append(team)
        try persist(env)
        return team
    }

    @discardableResult
    func updateTeam(
        org orgName: String, team teamName: String,
        description: String? = nil,
        permission: RepoMetaStore.Permission? = nil
    ) throws -> Team {
        var env = try loadOrInit()
        guard let oIdx = env.orgs.firstIndex(where: { $0.name == orgName }) else {
            throw StoreError.orgNotFound(orgName)
        }
        guard let tIdx = env.orgs[oIdx].teams.firstIndex(where: { $0.name == teamName }) else {
            throw StoreError.teamNotFound(org: orgName, team: teamName)
        }
        if teamName == "owners" && permission != nil {
            throw StoreError.invalidInput("cannot change permission of built-in 'owners' team")
        }
        if let d = description { env.orgs[oIdx].teams[tIdx].description = d }
        if let p = permission  { env.orgs[oIdx].teams[tIdx].permission  = p }
        try persist(env)
        return env.orgs[oIdx].teams[tIdx]
    }

    @discardableResult
    func deleteTeam(org orgName: String, team teamName: String) throws -> Bool {
        if teamName == "owners" {
            throw StoreError.invalidInput("cannot delete built-in 'owners' team")
        }
        var env = try loadOrInit()
        guard let oIdx = env.orgs.firstIndex(where: { $0.name == orgName }) else {
            throw StoreError.orgNotFound(orgName)
        }
        let before = env.orgs[oIdx].teams.count
        env.orgs[oIdx].teams.removeAll { $0.name == teamName }
        guard env.orgs[oIdx].teams.count != before else { return false }
        try persist(env)
        return true
    }

    @discardableResult
    func addTeamMember(org orgName: String, team teamName: String, user: String) throws -> Team {
        try validateMemberName(user)
        var env = try loadOrInit()
        guard let oIdx = env.orgs.firstIndex(where: { $0.name == orgName }) else {
            throw StoreError.orgNotFound(orgName)
        }
        guard let tIdx = env.orgs[oIdx].teams.firstIndex(where: { $0.name == teamName }) else {
            throw StoreError.teamNotFound(org: orgName, team: teamName)
        }
        if !env.orgs[oIdx].teams[tIdx].members.contains(user) {
            env.orgs[oIdx].teams[tIdx].members.append(user)
            env.orgs[oIdx].teams[tIdx].members.sort()
        }
        // Adding to "owners" team also makes them an owner.
        if teamName == "owners" && !env.orgs[oIdx].owners.contains(user) {
            env.orgs[oIdx].owners.append(user)
            env.orgs[oIdx].owners.sort()
        }
        try persist(env)
        return env.orgs[oIdx].teams[tIdx]
    }

    @discardableResult
    func removeTeamMember(org orgName: String, team teamName: String, user: String) throws -> Team {
        var env = try loadOrInit()
        guard let oIdx = env.orgs.firstIndex(where: { $0.name == orgName }) else {
            throw StoreError.orgNotFound(orgName)
        }
        guard let tIdx = env.orgs[oIdx].teams.firstIndex(where: { $0.name == teamName }) else {
            throw StoreError.teamNotFound(org: orgName, team: teamName)
        }
        // Removing from owners team also removes them as an owner;
        // don't allow removing the last owner that way.
        if teamName == "owners" {
            if env.orgs[oIdx].owners.count <= 1 && env.orgs[oIdx].owners.contains(user) {
                throw StoreError.lastOwner(orgName)
            }
            env.orgs[oIdx].owners.removeAll { $0 == user }
        }
        env.orgs[oIdx].teams[tIdx].members.removeAll { $0 == user }
        try persist(env)
        return env.orgs[oIdx].teams[tIdx]
    }

    @discardableResult
    func addTeamRepo(org orgName: String, team teamName: String, repo: String) throws -> Team {
        try validateRepoSpec(repo)
        var env = try loadOrInit()
        guard let oIdx = env.orgs.firstIndex(where: { $0.name == orgName }) else {
            throw StoreError.orgNotFound(orgName)
        }
        guard let tIdx = env.orgs[oIdx].teams.firstIndex(where: { $0.name == teamName }) else {
            throw StoreError.teamNotFound(org: orgName, team: teamName)
        }
        if !env.orgs[oIdx].teams[tIdx].repos.contains(repo) {
            env.orgs[oIdx].teams[tIdx].repos.append(repo)
            env.orgs[oIdx].teams[tIdx].repos.sort()
        }
        try persist(env)
        return env.orgs[oIdx].teams[tIdx]
    }

    @discardableResult
    func removeTeamRepo(org orgName: String, team teamName: String, repo: String) throws -> Team {
        var env = try loadOrInit()
        guard let oIdx = env.orgs.firstIndex(where: { $0.name == orgName }) else {
            throw StoreError.orgNotFound(orgName)
        }
        guard let tIdx = env.orgs[oIdx].teams.firstIndex(where: { $0.name == teamName }) else {
            throw StoreError.teamNotFound(org: orgName, team: teamName)
        }
        env.orgs[oIdx].teams[tIdx].repos.removeAll { $0 == repo }
        try persist(env)
        return env.orgs[oIdx].teams[tIdx]
    }

    // MARK: - Helpers

    private func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name else {
            throw StoreError.invalidInput("name must not be blank or padded")
        }
        guard trimmed.count >= 1 && trimmed.count <= 64 else {
            throw StoreError.invalidInput("name must be 1..64 chars")
        }
        guard RepositoryService.validateSegment(trimmed) else {
            throw StoreError.invalidInput("name '\(trimmed)' contains illegal characters")
        }
    }

    private func validateMemberName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidInput("member name must not be blank")
        }
    }

    private func validateRepoSpec(_ repo: String) throws {
        if repo == "*" { return }
        guard RepositoryService.validateSegment(repo) else {
            throw StoreError.invalidInput("repo spec '\(repo)' is not a valid repo name (or '*')")
        }
    }

    private func loadOrInit() throws -> Envelope {
        if let cached = envelope { return cached }
        let url = envelopeURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                let env = try dec.decode(Envelope.self, from: data)
                envelope = env
                return env
            } catch {
                throw StoreError.badEnvelope(String(describing: error))
            }
        }
        let env = Envelope(version: 1, orgs: [])
        envelope = env
        return env
    }

    private func envelopeURL() -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("orgs.json")
    }

    private func persist(_ env: Envelope) throws {
        envelope = env
        let url = envelopeURL()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try enc.encode(env) } catch {
            throw StoreError.ioFailed("encode: \(error)")
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("orgs.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try? FileManager.default.removeItem(at: tmp)
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw StoreError.ioFailed("persist: \(error)")
        }
    }
}
