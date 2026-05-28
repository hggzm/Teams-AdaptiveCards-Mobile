// hggz/giteax -- Phase 17: minimal Git LFS Batch API + raw object storage.
//
// Implements the Git LFS HTTP transfer spec: the `basic` transfer
// adapter only -- no SSH, no chunked, no multipart, no streaming
// upload via Azure/S3 indirection.
//
// Endpoints (all under the repo's smart-HTTP prefix):
//
//   POST   /:user/:repo.git/info/lfs/objects/batch
//          body: { operation: "upload"|"download",
//                  transfers: ["basic"], objects: [{oid, size}, ...] }
//          ->   { transfer: "basic",
//                 objects: [{ oid, size,
//                             actions: { upload: { href, header },
//                                        download: { href } },
//                             error?: { code, message } }] }
//
//   PUT    /:user/:repo.git/info/lfs/objects/:oid             (write+ auth)
//          raw body == object bytes; sha256 over body MUST equal :oid
//
//   GET    /:user/:repo.git/info/lfs/objects/:oid             (read auth)
//          response body == raw object bytes
//
//   POST   /:user/:repo.git/info/lfs/verify                   (write+ auth)
//          body: { oid, size }
//          -> 200 if object on disk with matching size, else 404/422
//
// Storage layout (Git-LFS convention):
//   <root>/.giteax/repos/<user>/<repo>/lfs/<oid[0..2]>/<oid[2..4]>/<oid>
//
// Object identity: sha256 hex (lowercase, exactly 64 chars). We verify
// on PUT by streaming the request body through SHA256; mismatched
// uploads get 422 with the offending OID echoed.
//
// Auth: download requires read on the repo (same gate as clone).
//       upload + verify require write (same gate as push) AND
//       GITEAX_ALLOW_PUSH=1 (same env-flag as smart-HTTP push).
//
// Limits: per-object 4 GiB hard cap. Adjust in `lfsObjectMaxBytes`.

import Vapor
import Foundation
import Crypto

private let lfsObjectMaxBytes = 4 * 1024 * 1024 * 1024   // 4 GiB

func registerLFSRoutes(
    _ app: Application,
    rootURL: URL,
    pushAuth: GitPushBasicAuth?,
    access: AccessController?
) {
    // MARK: - Helpers

    @Sendable
    func gateRead(_ req: Request, user: String, repo: String) async throws {
        guard let access else { return }
        let identity = await access.identify(req)
        do {
            try await access.requireRead(identity, user: user, repo: repo, scope: "this repository")
        } catch let e as AccessController.AccessError {
            throw Abort(e.status, headers: e.headers, reason: e.reason)
        }
    }

    /// Stash authenticated username on req.storage on success; throw
    /// 401 + WWW-Authenticate when missing/wrong. Mirrors the smart-HTTP
    /// pushAuth.gate that runs for git-receive-pack.
    ///
    /// On success returns the authenticated username. On gate failure,
    /// rethrows the original 401 response as an Abort so the request
    /// pipeline emits the WWW-Authenticate challenge correctly.
    @Sendable
    func gateWrite(_ req: Request, user: String, repo: String) async throws -> String {
        guard let pushAuth else {
            throw Abort(.serviceUnavailable, reason: "LFS writes disabled (server started without push auth)")
        }
        if let challenge = try await pushAuth.gate(req) {
            // gate() returns a fully-formed 401 with WWW-Authenticate.
            // Surface it via Abort so the response headers survive.
            var headers = HTTPHeaders()
            if let h = challenge.headers.first(name: .wwwAuthenticate) {
                headers.add(name: .wwwAuthenticate, value: h)
            }
            throw Abort(.unauthorized, headers: headers, reason: "authentication required for LFS uploads")
        }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        guard let access else { return name }
        do {
            try await access.require(
                AuthIdentity(name: name, isGlobalAdmin: false),
                atLeast: .write,
                user: user, repo: repo,
                scope: "uploading LFS objects to this repository"
            )
        } catch let e as AccessController.AccessError {
            throw Abort(e.status, headers: e.headers, reason: e.reason)
        }
        return name
    }

    /// Compute the on-disk path for a given (user, repo, oid) triple
    /// without touching disk.
    @Sendable
    func objectPath(user: String, repo: String, oid: String) -> URL {
        rootURL
            .appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos",   isDirectory: true)
            .appendingPathComponent(user,      isDirectory: true)
            .appendingPathComponent(repo,      isDirectory: true)
            .appendingPathComponent("lfs",     isDirectory: true)
            .appendingPathComponent(String(oid.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(oid.dropFirst(2).prefix(2)), isDirectory: true)
            .appendingPathComponent(oid, isDirectory: false)
    }

    /// Validate `oid`. SHA-256 hex is exactly 64 lower-case hex chars.
    @Sendable
    func validOID(_ s: String) -> Bool {
        guard s.count == 64 else { return false }
        for ch in s where !((ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f")) { return false }
        return true
    }

    /// Strip a trailing `.git` from a repo segment. SmartHTTP uses
    /// `:repo` interpolation that includes the `.git` suffix.
    @Sendable
    func cleanRepo(_ s: String) -> String {
        s.hasSuffix(".git") ? String(s.dropLast(4)) : s
    }

    // MARK: - POST /:user/:repo.git/info/lfs/objects/batch

    app.post(":user", ":repo", "info", "lfs", "objects", "batch") { req async throws -> Response in
        guard let userParam = req.parameters.get("user"),
              let repoParam = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        let user = userParam
        let repo = cleanRepo(repoParam)

        // Git LFS clients send `application/vnd.git-lfs+json`. Vapor's
        // content.decode insists on a recognised content-type, so decode
        // the body bytes directly through JSONDecoder.
        guard let buffer = req.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "empty request body")
        }
        let bodyData = Data(buffer: buffer)
        let dto: BatchRequestDTO
        do {
            dto = try JSONDecoder().decode(BatchRequestDTO.self, from: bodyData)
        } catch {
            throw Abort(.badRequest, reason: "malformed LFS batch JSON: \(error)")
        }
        let op = dto.operation.lowercased()
        guard op == "upload" || op == "download" else {
            throw Abort(.badRequest, reason: "unknown operation '\(dto.operation)'")
        }

        // Only `basic` is supported. If the client lists multiple
        // transfers, ours just has to appear in the list per spec.
        if let transfers = dto.transfers,
           !transfers.contains(where: { $0.lowercased() == "basic" }) {
            throw Abort(.notImplemented, reason: "only the `basic` transfer is supported")
        }

        // Auth: batch with op=download requires read; op=upload requires write.
        if op == "download" {
            try await gateRead(req, user: user, repo: repo)
        } else {
            _ = try await gateWrite(req, user: user, repo: repo)
        }

        // Build the absolute base URL for action hrefs from the request.
        let scheme = req.headers.first(name: "X-Forwarded-Proto") ?? "http"
        let host = req.headers.first(name: .host) ?? "localhost"
        let baseURL = "\(scheme)://\(host)/\(user)/\(repo).git/info/lfs/objects"

        // Forward the client's Authorization header (Basic or Bearer)
        // into the action header block so git-lfs's separate HTTP
        // session can authenticate the subsequent PUT / verify /
        // download requests. Without this the LFS client receives the
        // batch action URL but no credentials, then hits 401 on the
        // followup -- since git-lfs does NOT reuse the smart-HTTP
        // session's credentials by default. (Per git-lfs spec:
        // server-supplied `header` is the canonical auth channel.)
        let actionHeaders: [String: String]?
        if let authHeader = req.headers.first(name: .authorization) {
            actionHeaders = ["Authorization": authHeader]
        } else {
            actionHeaders = nil
        }

        var outObjects: [BatchResponseObject] = []
        for obj in dto.objects {
            guard validOID(obj.oid) else {
                outObjects.append(BatchResponseObject(
                    oid: obj.oid, size: obj.size, authenticated: true,
                    actions: nil,
                    error: BatchObjectError(code: 422, message: "invalid OID; expected 64-char lower-case sha256 hex")
                ))
                continue
            }
            guard obj.size >= 0, obj.size <= lfsObjectMaxBytes else {
                outObjects.append(BatchResponseObject(
                    oid: obj.oid, size: obj.size, authenticated: true,
                    actions: nil,
                    error: BatchObjectError(code: 422, message: "size out of range (0..\(lfsObjectMaxBytes))")
                ))
                continue
            }

            let path = objectPath(user: user, repo: repo, oid: obj.oid)
            let exists = FileManager.default.fileExists(atPath: path.path)

            switch op {
            case "download":
                if exists {
                    outObjects.append(BatchResponseObject(
                        oid: obj.oid, size: obj.size, authenticated: true,
                        actions: ActionsDTO(download: ActionDTO(href: "\(baseURL)/\(obj.oid)", header: actionHeaders), upload: nil, verify: nil),
                        error: nil
                    ))
                } else {
                    outObjects.append(BatchResponseObject(
                        oid: obj.oid, size: obj.size, authenticated: true,
                        actions: nil,
                        error: BatchObjectError(code: 404, message: "object not found")
                    ))
                }
            case "upload":
                if exists {
                    // Per spec: object already exists -> no actions block.
                    outObjects.append(BatchResponseObject(
                        oid: obj.oid, size: obj.size, authenticated: true,
                        actions: nil,
                        error: nil
                    ))
                } else {
                    outObjects.append(BatchResponseObject(
                        oid: obj.oid, size: obj.size, authenticated: true,
                        actions: ActionsDTO(
                            download: nil,
                            upload: ActionDTO(href: "\(baseURL)/\(obj.oid)", header: actionHeaders),
                            verify: ActionDTO(href: "\(scheme)://\(host)/\(user)/\(repo).git/info/lfs/verify", header: actionHeaders)
                        ),
                        error: nil
                    ))
                }
            default: break  // unreachable
            }
        }

        let body = BatchResponseDTO(transfer: "basic", objects: outObjects)
        let r = Response(status: .ok)
        r.headers.replaceOrAdd(name: .contentType, value: "application/vnd.git-lfs+json")
        try r.content.encode(body, as: .json)
        return r
    }

    // MARK: - PUT /:user/:repo.git/info/lfs/objects/:oid  (upload)

    app.on(.PUT, ":user", ":repo", "info", "lfs", "objects", ":oid",
           body: .collect(maxSize: ByteCount(value: lfsObjectMaxBytes)))
    { req async throws -> Response in
        guard let userParam = req.parameters.get("user"),
              let repoParam = req.parameters.get("repo"),
              let oid       = req.parameters.get("oid")
        else { throw Abort(.badRequest, reason: "missing path parameters") }
        let user = userParam
        let repo = cleanRepo(repoParam)
        guard validOID(oid) else { throw Abort(.badRequest, reason: "invalid OID") }
        _ = try await gateWrite(req, user: user, repo: repo)

        // Collect body bytes (already capped by .collect).
        let body: Data
        if let buffer = req.body.data {
            body = Data(buffer: buffer)
        } else {
            body = Data()
        }
        guard !body.isEmpty else { throw Abort(.badRequest, reason: "empty body") }

        // Verify sha256.
        let digest = SHA256.hash(data: body)
        let actualOID = digest.map { String(format: "%02x", $0) }.joined()
        guard actualOID == oid else {
            throw Abort(.unprocessableEntity, reason: "OID mismatch: claimed \(oid), got \(actualOID)")
        }

        // Persist using the temp+move triple (atomic on Windows).
        let dest = objectPath(user: user, repo: repo, oid: oid)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let tmp = dest.deletingLastPathComponent()
                .appendingPathComponent(oid + ".tmp-\(ProcessInfo.processInfo.processIdentifier)")
            try? fm.removeItem(at: tmp)
            try body.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            throw Abort(.internalServerError, reason: "failed to persist LFS object: \(error)")
        }
        let r = Response(status: .ok)
        r.headers.replaceOrAdd(name: .contentType, value: "application/vnd.git-lfs+json")
        r.body = .init(string: "{}")
        return r
    }

    // MARK: - GET /:user/:repo.git/info/lfs/objects/:oid  (download)

    app.get(":user", ":repo", "info", "lfs", "objects", ":oid") { req async throws -> Response in
        guard let userParam = req.parameters.get("user"),
              let repoParam = req.parameters.get("repo"),
              let oid       = req.parameters.get("oid")
        else { throw Abort(.badRequest, reason: "missing path parameters") }
        let user = userParam
        let repo = cleanRepo(repoParam)
        guard validOID(oid) else { throw Abort(.badRequest, reason: "invalid OID") }
        try await gateRead(req, user: user, repo: repo)

        let path = objectPath(user: user, repo: repo, oid: oid)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            throw Abort(.notFound, reason: "LFS object \(oid) not found")
        }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw Abort(.internalServerError, reason: "failed to read LFS object: \(error)")
        }
        let r = Response(status: .ok)
        r.headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
        r.headers.replaceOrAdd(name: "X-Giteax-LFS-OID", value: oid)
        r.body = .init(data: data)
        return r
    }

    // MARK: - POST /:user/:repo.git/info/lfs/verify

    app.post(":user", ":repo", "info", "lfs", "verify") { req async throws -> Response in
        guard let userParam = req.parameters.get("user"),
              let repoParam = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        let user = userParam
        let repo = cleanRepo(repoParam)
        _ = try await gateWrite(req, user: user, repo: repo)
        // Same manual decode dance as /batch above (application/vnd.git-lfs+json).
        guard let buffer = req.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "empty request body")
        }
        let bodyData = Data(buffer: buffer)
        let dto: VerifyRequestDTO
        do {
            dto = try JSONDecoder().decode(VerifyRequestDTO.self, from: bodyData)
        } catch {
            throw Abort(.badRequest, reason: "malformed verify JSON: \(error)")
        }
        guard validOID(dto.oid) else { throw Abort(.badRequest, reason: "invalid OID") }
        let path = objectPath(user: user, repo: repo, oid: dto.oid)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            throw Abort(.notFound, reason: "object not found")
        }
        let attrs = try? fm.attributesOfItem(atPath: path.path)
        let actualSize = (attrs?[.size] as? NSNumber)?.intValue ?? -1
        guard actualSize == dto.size else {
            throw Abort(.unprocessableEntity, reason: "size mismatch: stored=\(actualSize) claimed=\(dto.size)")
        }
        let r = Response(status: .ok)
        r.headers.replaceOrAdd(name: .contentType, value: "application/vnd.git-lfs+json")
        r.body = .init(string: "{}")
        return r
    }
}

// MARK: - DTOs

private struct BatchRequestDTO: Content {
    let operation: String
    let transfers: [String]?
    let objects: [BatchRequestObject]
}

private struct BatchRequestObject: Content {
    let oid: String
    let size: Int
}

private struct BatchResponseDTO: Content {
    let transfer: String
    let objects: [BatchResponseObject]
}

private struct BatchResponseObject: Content {
    let oid: String
    let size: Int
    let authenticated: Bool
    let actions: ActionsDTO?
    let error: BatchObjectError?
}

private struct ActionsDTO: Content {
    let download: ActionDTO?
    let upload: ActionDTO?
    let verify: ActionDTO?
}

private struct ActionDTO: Content {
    let href: String
    let header: [String: String]?
}

private struct BatchObjectError: Content {
    let code: Int
    let message: String
}

private struct VerifyRequestDTO: Content {
    let oid: String
    let size: Int
}
