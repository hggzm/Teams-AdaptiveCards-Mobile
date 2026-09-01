import Foundation
import Vapor

/// Filesystem-backed per-repo metadata store (Phase 12).
///
/// On-disk shape (sibling of issues.json / prs.json / webhooks.json):
///
///     <root>/.giteax/repos/<user>/<repo>/meta.json
///       {
///         "version": 1,
///         "visibility": "public" | "private" | "internal",
///         "description": "...",
///         "defaultBranch": "main",
///         "collaborators": {
///           "alice": "admin",
///           "bob":   "write",
///           "carol": "read"
///         }
///       }
///
/// Visibility semantics for `GET` traffic (clone, browse, issue / PR
/// list, etc.):
///   public   -- anyone can read; no auth required
///   internal -- any AUTHENTICATED user can read (not just collaborators)
///   private  -- only the owner, global admins, and listed collaborators
///
/// Write traffic always requires authentication. Permission level then
/// gates the operation:
///   read     -- can clone / fetch / browse / list issues+PRs / read comments
///   write    -- + push / open issue / open PR / comment / merge PR
///   admin    -- + edit settings / manage collaborators / manage webhooks
///
/// Implicit grants:
///   - The "owner" (user whose namespace the repo lives under) is admin.
///   - Global admins from users.json are admin on every repo.
///
/// If meta.json is missing for an existing on-disk repo, we lazily
/// create a public/no-collaborators record. This preserves the
/// pre-Phase-12 public-by-default behaviour for repos that existed
/// before the ACL layer landed.
actor RepoMetaStore {

    enum Visibility: String, Sendable, Codable, CaseIterable {
        case `public`
        case `private`
        case `internal`
    }

    /// Capability level granted to a collaborator. Comparable so we can
    /// write `level >= .write` to check writeability.
    enum Permission: String, Sendable, Codable, CaseIterable, Comparable {
        case read
        case write
        case admin

        private var rank: Int {
            switch self {
            case .read: 0
            case .write: 1
            case .admin: 2
            }
        }
        static func < (lhs: Permission, rhs: Permission) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    struct Meta: Sendable, Codable {
        var version: Int
        var visibility: Visibility
        var description: String?
        var defaultBranch: String?
        var collaborators: [String: Permission]
        /// Phase 13: branches that require ADMIN to push to. Empty by
        /// default. Pattern matching is exact-name only in v0.0.12
        /// (no globs); think of it as a small set of named "release"
        /// branches that day-to-day writers can clone+read but only
        /// admins can rewrite.
        var protectedBranches: [String]?
        /// Phase 27/28: random per-repo secret used by the auto-
        /// installed post-receive / pre-receive hooks to authenticate
        /// back to the giteax internal endpoints. Lazily generated on
        /// the first push that runs HookInstaller. Nil for pre-0.0.16
        /// repos until they accept their next push.
        var hookToken: String?
        /// Phase 36: minimum number of distinct non-author reviewers
        /// whose latest review state is `approved` required before a
        /// PR can be merged. Nil/0 disables the gate (default).
        var requiredApprovals: Int?
    }

    enum StoreError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound: .notFound
            case .invalidInput: .badRequest
            case .ioFailed, .badEnvelope: .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .repoNotFound(let u, let r): "no repository at \(u)/\(r)"
            case .invalidInput(let d): "invalid meta input: \(d)"
            case .ioFailed(let d): "meta-store I/O failed: \(d)"
            case .badEnvelope(let d): "meta-store JSON malformed: \(d)"
            }
        }
    }

    let root: URL
    private var cache: [String: Meta] = [:]

    init(root: URL) throws {
        let dir = root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        self.root = root
    }

    // MARK: - Read

    func get(user: String, repo: String) throws -> Meta {
        try loadOrInit(user: user, repo: repo)
    }

    /// Phase 44: drop any cached `Meta` for `user/repo`. Called by
    /// transfer/rename right before the on-disk move so subsequent
    /// reads under the old path hit a clean slate (which then maps to
    /// `repoNotFound` once the bare dir is gone).
    func evictRepo(user: String, repo: String) {
        cache.removeValue(forKey: "\(user)/\(repo)")
    }

    // MARK: - Mutate

    /// Patch visibility / description / defaultBranch. Pass nil to leave
    /// unchanged. Collaborators are managed via the dedicated methods
    /// below so the wire format stays explicit.
    @discardableResult
    func update(
        user: String, repo: String,
        visibility: Visibility? = nil,
        description: String? = nil,
        defaultBranch: String? = nil,
        protectedBranches: [String]? = nil,
        requiredApprovals: Int? = nil
    ) throws -> Meta {
        var meta = try loadOrInit(user: user, repo: repo)
        if let v = visibility { meta.visibility = v }
        if let d = description { meta.description = d.isEmpty ? nil : d }
        if let b = defaultBranch {
            let t = b.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {
                meta.defaultBranch = nil
            } else {
                guard RepositoryService.validateSegment(t) else {
                    throw StoreError.invalidInput("defaultBranch '\(t)' is not a valid name")
                }
                meta.defaultBranch = t
            }
        }
        if let p = protectedBranches {
            // Validate + dedupe each entry. Empty list clears protections.
            var seen = Set<String>()
            var out: [String] = []
            for raw in p {
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                guard RepositoryService.validateSegment(t) else {
                    throw StoreError.invalidInput("protected-branch entry '\(t)' is not a valid name")
                }
                if seen.insert(t).inserted { out.append(t) }
            }
            meta.protectedBranches = out.isEmpty ? nil : out
        }
        if let n = requiredApprovals {
            guard n >= 0, n <= 100 else {
                throw StoreError.invalidInput("requiredApprovals must be 0...100")
            }
            meta.requiredApprovals = n == 0 ? nil : n
        }
        try persist(meta, user: user, repo: repo)
        return meta
    }

    /// Phase 27/28: return the current hook token, generating + persisting
    /// one if absent. Idempotent on subsequent calls. Uses 128 bits of
    /// hex via UUID -- not cryptographically perfect, but more than
    /// enough for the loopback-only internal hook channel.
    @discardableResult
    func ensureHookToken(user: String, repo: String) throws -> (token: String, didCreate: Bool) {
        var meta = try loadOrInit(user: user, repo: repo)
        if let t = meta.hookToken, !t.isEmpty {
            return (t, false)
        }
        let tok = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        meta.hookToken = tok
        try persist(meta, user: user, repo: repo)
        return (tok, true)
    }

    /// Phase 27/28: validate a hook callback token. Constant-time compare
    /// over the byte sequence; returns false if the meta couldn't be
    /// loaded or the token is empty/mismatched.
    func validateHookToken(user: String, repo: String, presented: String) -> Bool {
        guard let meta = try? loadOrInit(user: user, repo: repo) else { return false }
        guard let stored = meta.hookToken, !stored.isEmpty else { return false }
        // Constant-time compare to avoid timing leaks; the surface is tiny
        // but the cost is negligible.
        let a = Array(stored.utf8)
        let b = Array(presented.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Convenience: is this branch protected on this repo?
    func isProtected(user: String, repo: String, branch: String) -> Bool {
        guard let env = try? loadOrInit(user: user, repo: repo) else { return false }
        return env.protectedBranches?.contains(branch) == true
    }

    @discardableResult
    func setCollaborator(
        user: String, repo: String,
        name: String, permission: Permission
    ) throws -> Meta {
        guard RepositoryService.validateSegment(name) else {
            throw StoreError.invalidInput("collaborator name '\(name)' is invalid")
        }
        // Refuse to overwrite the owner's implicit admin -- it's already
        // there, and explicit grants on the owner would be confusing.
        guard name != user else {
            throw StoreError.invalidInput("owner '\(name)' is implicitly admin; no explicit grant needed")
        }
        var meta = try loadOrInit(user: user, repo: repo)
        meta.collaborators[name] = permission
        try persist(meta, user: user, repo: repo)
        return meta
    }

    @discardableResult
    func removeCollaborator(
        user: String, repo: String, name: String
    ) throws -> Meta {
        var meta = try loadOrInit(user: user, repo: repo)
        guard meta.collaborators.removeValue(forKey: name) != nil else {
            throw StoreError.invalidInput("'\(name)' is not a collaborator")
        }
        try persist(meta, user: user, repo: repo)
        return meta
    }

    // MARK: - Helpers

    private func loadOrInit(user: String, repo: String) throws -> Meta {
        let key = "\(user)/\(repo)"
        if let cached = cache[key] { return cached }
        if !repoExistsOnDisk(user: user, repo: repo) {
            throw StoreError.repoNotFound(user: user, repo: repo)
        }
        let url = envelopeURL(user: user, repo: repo)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let dec = JSONDecoder()
                let m = try dec.decode(Meta.self, from: data)
                cache[key] = m
                return m
            } catch {
                throw StoreError.badEnvelope(String(describing: error))
            }
        }
        // Lazy default for repos that pre-date Phase 12: public, no
        // explicit collaborators. Preserves prior behaviour.
        let m = Meta(
            version: 1,
            visibility: .public,
            description: nil,
            defaultBranch: nil,
            collaborators: [:]
        )
        cache[key] = m
        // Don't auto-persist on read -- only write when something
        // actually changes. This keeps disk traffic predictable.
        return m
    }

    private func repoExistsOnDisk(user: String, repo: String) -> Bool {
        let bare = root.appendingPathComponent(user)
            .appendingPathComponent("\(repo).git")
        if FileManager.default.fileExists(atPath: bare.path) { return true }
        let working = root.appendingPathComponent(user).appendingPathComponent(repo)
        return FileManager.default.fileExists(atPath: working.path)
    }

    private func envelopeURL(user: String, repo: String) -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(user, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("meta.json")
    }

    private func persist(_ meta: Meta, user: String, repo: String) throws {
        let key = "\(user)/\(repo)"
        cache[key] = meta
        let url = envelopeURL(user: user, repo: repo)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw StoreError.ioFailed("mkdir: \(error)")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try enc.encode(meta)
        } catch {
            throw StoreError.ioFailed("encode: \(error)")
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("meta.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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

/// Identity carried through the request stack. `nil` username means
/// anonymous; an admin username from the user store is implicitly
/// admin everywhere.
struct AuthIdentity: Sendable {
    let name: String?
    /// True iff the resolved user is a global admin (from `users.json`).
    let isGlobalAdmin: Bool

    static let anonymous = AuthIdentity(name: nil, isGlobalAdmin: false)
}

/// Single decision point for every permission check across the server.
/// Reads from RepoMetaStore + UserStore; writes through neither.
struct AccessController: Sendable {
    let meta: RepoMetaStore
    let users: UserStore
    /// Phase 40: optional org store. When set, the AC consults it any
    /// time the path's owner segment matches a registered org name.
    var orgs: OrgStore? = nil

    enum AccessError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case authRequired(scope: String)
        case forbidden(reason: String)

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound: .notFound
            case .authRequired: .unauthorized
            case .forbidden:    .forbidden
            }
        }
        var reason: String {
            switch self {
            case .repoNotFound(let u, let r): "no repository at \(u)/\(r)"
            case .authRequired(let s): "authentication required for \(s)"
            case .forbidden(let r): r
            }
        }
        var headers: HTTPHeaders {
            switch self {
            case .authRequired:
                var h = HTTPHeaders()
                h.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
                return h
            default: return [:]
            }
        }
    }

    /// Resolve identity from an HTTP request. Tries Basic auth first;
    /// returns `.anonymous` when there's no Authorization header.
    /// Failed verification returns `.anonymous` too -- the route's
    /// permission check will reject with 401 if auth was required.
    func identify(_ req: Request) async -> AuthIdentity {
        guard let basic = req.headers.basicAuthorization else {
            return .anonymous
        }
        guard let user = await users.verify(name: basic.username, password: basic.password) else {
            return .anonymous
        }
        return AuthIdentity(name: user.name, isGlobalAdmin: user.isAdmin)
    }

    /// Effective permission for `identity` on `user/repo`, with `nil`
    /// meaning "no access at all". Encodes:
    ///   - global admins      -> .admin everywhere
    ///   - owner of the repo  -> .admin
    ///   - explicit collab    -> their grant
    ///   - public repo, anon  -> .read
    ///   - internal repo, any authed user -> .read
    ///   - private repo, no other grant   -> nil
    func effectivePermission(
        identity: AuthIdentity,
        user: String, repo: String
    ) async throws -> RepoMetaStore.Permission? {
        let m: RepoMetaStore.Meta
        do {
            m = try await meta.get(user: user, repo: repo)
        } catch let e as RepoMetaStore.StoreError {
            // Surface "repo not found" cleanly to the route layer.
            if case .repoNotFound(let u, let r) = e {
                throw AccessError.repoNotFound(user: u, repo: r)
            }
            throw e
        }
        if identity.isGlobalAdmin { return .admin }
        if let name = identity.name {
            if name == user { return .admin }                     // owner
            if let p = m.collaborators[name] { return p }
        }
        // Phase 40: when the path's owner is an org, derive permissions
        // from team membership (org owners are admin everywhere).
        if let orgs, let name = identity.name,
           (try? await orgs.isOrg(user)) == true {
            if let teamPerm = try await orgs.effectivePermission(
                org: user, repo: repo, user: name
            ) {
                return teamPerm
            }
        }
        switch m.visibility {
        case .public:
            return .read
        case .internal:
            return identity.name != nil ? .read : nil
        case .private:
            return nil
        }
    }

    /// Convenience: throws if `identity` can't read `user/repo`.
    func requireRead(_ identity: AuthIdentity, user: String, repo: String, scope: String = "this repository") async throws {
        let p = try await effectivePermission(identity: identity, user: user, repo: repo)
        if p == nil {
            // For private repos, distinguish anon-missing-auth from
            // authed-but-no-grant: anon gets 401 + WWW-Authenticate so
            // clients can prompt for credentials; authed gets 404 so we
            // don't leak repo existence to outsiders.
            if identity.name == nil {
                throw AccessError.authRequired(scope: scope)
            } else {
                throw AccessError.repoNotFound(user: user, repo: repo)
            }
        }
    }

    /// Throws if `identity` doesn't meet the minimum permission.
    func require(
        _ identity: AuthIdentity,
        atLeast required: RepoMetaStore.Permission,
        user: String, repo: String,
        scope: String
    ) async throws {
        let p = try await effectivePermission(identity: identity, user: user, repo: repo)
        switch p {
        case .none:
            if identity.name == nil {
                throw AccessError.authRequired(scope: scope)
            }
            throw AccessError.repoNotFound(user: user, repo: repo)
        case .some(let actual):
            if actual < required {
                throw AccessError.forbidden(reason: "\(scope) requires \(required.rawValue) (you have \(actual.rawValue))")
            }
        }
    }

    /// Phase 13: check whether `identity` can push to `branch` on
    /// `user/repo`. Combines the standard write check with the per-repo
    /// protected-branches list: a branch in `protectedBranches` requires
    /// `admin` instead of just `write`.
    ///
    /// `branch == nil` means "the push is not tied to a single branch"
    /// (e.g. tag-only pushes); we conservatively gate at admin level if
    /// ANY branch is protected -- prevents an authed writer from sneaking
    /// in a force-push that touches multiple refs.
    func requireBranchWrite(
        _ identity: AuthIdentity,
        user: String, repo: String, branch: String?,
        scope: String
    ) async throws {
        let needsAdmin: Bool
        if let branch {
            needsAdmin = await meta.isProtected(user: user, repo: repo, branch: branch)
        } else {
            let m = (try? await meta.get(user: user, repo: repo))
            needsAdmin = (m?.protectedBranches?.isEmpty == false)
        }
        try await require(
            identity,
            atLeast: needsAdmin ? .admin : .write,
            user: user, repo: repo, scope: scope
        )
    }
}
