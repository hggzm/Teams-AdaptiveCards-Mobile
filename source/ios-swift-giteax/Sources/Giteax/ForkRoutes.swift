import Foundation
import Vapor

/// Phase 41: fork HTTP API.
///
///   POST   /api/repos/:user/:repo/forks       (auth)  body: {owner?, name?}
///   GET    /api/repos/:user/:repo/forks       (open)  list direct children
///   GET    /api/repos/:user/:repo/parent      (open)  parent or 404
///
/// Forking semantics:
///   - The new fork lives at `<root>/<targetOwner>/<name>.git` (a bare
///     clone of the source bare repo). `targetOwner` defaults to the
///     authenticated requester; if the body specifies a different
///     owner, it must be either the requester themselves OR an org
///     in which the requester is an owner.
///   - `name` defaults to the source repo's name.
///   - Refuses to overwrite an existing repo.
///   - Records the lineage in ForkStore so `GET .../parent` and the
///     cross-fork PR machinery (Phase 41 PR step) can resolve it.
func registerForkRoutes(
    _ app: Application,
    forks: ForkStore,
    orgs: OrgStore?,
    pushAuth: GitPushBasicAuth?,
    access: AccessController?,
    rootURL: URL
) {

    @Sendable
    func requireAuthor(_ req: Request) async throws -> String {
        guard let pushAuth else {
            throw Abort(.forbidden, reason: "fork creation disabled (set GITEAX_ALLOW_PUSH=1 and create a user)")
        }
        if let _ = try await pushAuth.gate(req) {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm=\"giteax\""#)
            throw Abort(.unauthorized, headers: headers, reason: "authentication required to fork")
        }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        return name
    }

    // MARK: - Reads

    app.get("api", "repos", ":user", ":repo", "forks") { req async throws -> Response in
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }
        let kids = try await forks.childrenOf(.init(owner: u, repo: r))
        let dto = ForkListDTO(
            user: u, repo: r,
            count: kids.count,
            forks: kids.map(ForkDTO.from)
        )
        let resp = Response(status: .ok)
        try resp.content.encode(dto, as: .json)
        return resp
    }

    app.get("api", "repos", ":user", ":repo", "parent") { req async throws -> Response in
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }
        guard let p = try await forks.parent(of: .init(owner: u, repo: r)) else {
            throw Abort(.notFound, reason: "no parent: \(u)/\(r) is not a fork")
        }
        let resp = Response(status: .ok)
        try resp.content.encode(RepoRefDTO(owner: p.owner, repo: p.repo), as: .json)
        return resp
    }

    // MARK: - Create

    app.post("api", "repos", ":user", ":repo", "forks") { req async throws -> Response in
        guard let srcOwner = req.parameters.get("user"),
              let srcRepo  = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }

        let author = try await requireAuthor(req)

        // Read access on the source repo. (You can fork any repo you can read.)
        if let access {
            let identity = await access.identify(req)
            do {
                try await access.requireRead(identity, user: srcOwner, repo: srcRepo, scope: "forking")
            } catch let e as AccessController.AccessError {
                throw Abort(e.status, headers: e.headers, reason: e.reason)
            }
        }

        // Resolve source bare-repo path.
        let srcURL = rootURL.appendingPathComponent(srcOwner)
            .appendingPathComponent("\(srcRepo).git")
        guard FileManager.default.fileExists(atPath: srcURL.path) else {
            throw Abort(.notFound, reason: "source bare repo not found: \(srcOwner)/\(srcRepo).git")
        }

        let body = (try? req.content.decode(CreateForkDTO.self)) ?? CreateForkDTO(owner: nil, name: nil)
        let targetOwner = (body.owner?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? author
        let targetRepo  = (body.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? srcRepo

        guard RepositoryService.validateSegment(targetOwner),
              RepositoryService.validateSegment(targetRepo)
        else { throw Abort(.badRequest, reason: "owner/name must match [A-Za-z0-9][A-Za-z0-9._-]*") }

        // Authorize the target owner.
        if targetOwner != author {
            // Org owner check.
            if let orgs, let org = try await orgs.get(targetOwner) {
                guard org.owners.contains(author) else {
                    throw Abort(.forbidden, reason: "must be an owner of organization '\(targetOwner)' to fork into it")
                }
            } else {
                throw Abort(.forbidden, reason: "target owner '\(targetOwner)' is neither you nor an org you own")
            }
        }

        // Refuse forking onto self (same path).
        if targetOwner == srcOwner && targetRepo == srcRepo {
            throw Abort(.conflict, reason: "cannot fork a repo onto itself")
        }

        let dstDir = rootURL.appendingPathComponent(targetOwner)
        let dstRepo = dstDir.appendingPathComponent("\(targetRepo).git")
        if FileManager.default.fileExists(atPath: dstRepo.path) {
            throw Abort(.conflict, reason: "target repo already exists: \(targetOwner)/\(targetRepo).git")
        }
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

        // git clone --bare <srcURL> <dstRepo>
        let p = Process()
        guard let gitPath = which("git") else {
            throw Abort(.internalServerError, reason: "git executable not found in PATH")
        }
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = ["clone", "--bare", "--quiet", srcURL.path, dstRepo.path]
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            throw Abort(.internalServerError, reason: "could not invoke git at \(gitPath) (cwd=\(FileManager.default.currentDirectoryPath)): \(error)")
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let errData = (errPipe.fileHandleForReading.readDataToEndOfFile())
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            // Best-effort cleanup so retries are clean.
            try? FileManager.default.removeItem(at: dstRepo)
            throw Abort(.internalServerError,
                reason: "git clone --bare failed (exit \(p.terminationStatus)): \(errStr.prefix(400))")
        }

        do {
            let fork = try await forks.registerFork(
                child:  .init(owner: targetOwner, repo: targetRepo),
                parent: .init(owner: srcOwner,    repo: srcRepo),
                createdBy: author
            )
            let resp = Response(status: .created)
            try resp.content.encode(ForkDTO.from(fork), as: .json)
            return resp
        } catch let e as ForkStore.StoreError {
            // Roll back the clone if the lineage record fails.
            try? FileManager.default.removeItem(at: dstRepo)
            throw Abort(e.status, reason: e.reason)
        }
    }
}

@Sendable
private func which(_ exe: String) -> String? {
    #if os(Windows)
    let sep: Character = ";"
    // Outer loop is by EXTENSION, not by directory, so a real .exe in a
    // later PATH dir wins over a .cmd shim earlier in PATH (e.g. Azure
    // CLI's git.cmd, which Foundation.Process can't invoke directly).
    let exts = [".exe", ".cmd", ".bat", ""]
    #else
    let sep: Character = ":"
    let exts = [""]
    #endif
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    let dirs = path.split(separator: sep)
    for ext in exts {
        for dir in dirs {
            let candidate = URL(fileURLWithPath: String(dir))
                .appendingPathComponent(exe + ext)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
    }
    return nil
}

// MARK: - DTOs

private struct CreateForkDTO: Content {
    let owner: String?
    let name: String?
}

private struct RepoRefDTO: Content {
    let owner: String
    let repo: String
}

private struct ForkDTO: Content {
    let owner: String
    let repo: String
    let parentOwner: String
    let parentRepo: String
    let createdBy: String
    let createdAt: Date

    static func from(_ f: ForkStore.Fork) -> ForkDTO {
        ForkDTO(
            owner: f.child.owner, repo: f.child.repo,
            parentOwner: f.parent.owner, parentRepo: f.parent.repo,
            createdBy: f.createdBy, createdAt: f.createdAt
        )
    }
}

private struct ForkListDTO: Content {
    let user: String
    let repo: String
    let count: Int
    let forks: [ForkDTO]
}
