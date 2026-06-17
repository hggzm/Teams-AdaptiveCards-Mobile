import Foundation
import Vapor

/// Shells out to `git http-backend` (the CGI helper that ships with git)
/// to serve the smart-HTTP protocol.
///
/// The git smart-HTTP wire protocol expects these endpoints, all under
/// `/<user>/<repo>.git/`:
///   - `GET  /info/refs?service=git-upload-pack`   (clone discovery)
///   - `GET  /info/refs?service=git-receive-pack`  (push discovery)
///   - `POST /git-upload-pack`                     (clone data)
///   - `POST /git-receive-pack`                    (push data)
///
/// `git http-backend` is a CGI executable: it reads request bytes from
/// stdin, environment variables for routing, and writes a CGI-style
/// response (headers, blank line, body) to stdout. We spawn it as a
/// subprocess, pipe the request body in, parse its output, and turn it
/// into a Vapor `Response`.
///
/// Phase 7 v1 buffers the entire request and response in memory. Real
/// pack-builder streaming for large clones / pushes is a future
/// optimisation -- the buffered approach gives correctness end-to-end
/// for typical repo sizes (single-digit-to-low-double-digit MB).
struct SmartHTTPService: Sendable {
    /// Absolute path to the directory containing `<user>/<repo>.git`.
    let root: URL
    /// Absolute path to the `git-http-backend` CGI executable.
    let backend: URL
    /// When false, POST `git-receive-pack` is refused with 403 Forbidden.
    /// Gated independently of read-only operations because there's no
    /// authentication layer yet -- anyone hitting the server could
    /// otherwise rewrite history anonymously.
    let allowPush: Bool

    /// CGI response after parsing `git http-backend`'s stdout output.
    struct Response: Sendable {
        let status: HTTPResponseStatus
        let headers: HTTPHeaders
        let body: Data
    }

    enum BackendError: Error, AbortError {
        case invalidName(String)
        case notFound(user: String, repo: String)
        case pushDisabled
        case backendMissing
        case backendFailed(exitCode: Int32, stderr: String)
        case cgiParseFailed(String)

        var status: HTTPResponseStatus {
            switch self {
            case .invalidName:      .badRequest
            case .notFound:         .notFound
            case .pushDisabled:     .forbidden
            case .backendMissing:   .internalServerError
            case .backendFailed:    .badGateway
            case .cgiParseFailed:   .badGateway
            }
        }
        var reason: String {
            switch self {
            case .invalidName(let n):
                return "invalid path segment: '\(n)'"
            case .notFound(let user, let repo):
                return "no repository at \(user)/\(repo)"
            case .pushDisabled:
                return "push is disabled (set GITEAX_ALLOW_PUSH=1 to enable)"
            case .backendMissing:
                return "git-http-backend not found on this host"
            case .backendFailed(let code, let stderr):
                return "git-http-backend exited \(code): \(stderr)"
            case .cgiParseFailed(let detail):
                return "could not parse CGI response from git-http-backend: \(detail)"
            }
        }
    }

    // MARK: - Init

    /// Construct a service. If `backendOverride` is nil, attempts to
    /// auto-discover `git-http-backend(.exe)` by asking `git --exec-path`
    /// at construction time.
    init(root: URL, backendOverride: URL? = nil, allowPush: Bool) throws {
        self.root = root
        self.allowPush = allowPush
        if let override = backendOverride {
            self.backend = override
        } else if let discovered = Self.discoverBackend() {
            self.backend = discovered
        } else {
            throw BackendError.backendMissing
        }
    }

    /// Ask `git --exec-path` for the libexec dir, then look for
    /// `git-http-backend(.exe)` inside it. Returns nil if anything fails.
    /// Honors `GITEAX_GIT_HTTP_BACKEND` (absolute path) as a hard override.
    static func discoverBackend() -> URL? {
        // 0. Hard override.
        if let manual = ProcessInfo.processInfo.environment["GITEAX_GIT_HTTP_BACKEND"],
           !manual.isEmpty,
           FileManager.default.isExecutableFile(atPath: manual) {
            return URL(fileURLWithPath: manual)
        }
        // 1. Ask `git --exec-path`.
        if let dir = Self.gitExecPath() {
            for name in Self.backendNames() {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        // 2. Walk a handful of well-known install locations for OSes where
        // `git --exec-path` couldn't be resolved (e.g. `git` not on PATH
        // when the Swift binary was launched from a stripped-down shell).
        for candidate in Self.wellKnownBackendPaths() {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Wrap `git --exec-path` invocation; returns the trimmed stdout or nil.
    private static func gitExecPath() -> String? {
        guard let gitPath = Self.findGit() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["--exec-path"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    private static func backendNames() -> [String] {
        #if os(Windows)
        return ["git-http-backend.exe", "git-http-backend"]
        #else
        return ["git-http-backend"]
        #endif
    }

    /// Static fallback locations for `git-http-backend(.exe)` when
    /// `git --exec-path` isn't usable.
    private static func wellKnownBackendPaths() -> [String] {
        #if os(Windows)
        return [
            #"C:\Program Files\Git\mingw64\libexec\git-core\git-http-backend.exe"#,
            #"C:\Program Files (x86)\Git\mingw32\libexec\git-core\git-http-backend.exe"#,
        ]
        #elseif os(macOS)
        return [
            "/usr/local/libexec/git-core/git-http-backend",
            "/opt/homebrew/libexec/git-core/git-http-backend",
            "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-http-backend",
            "/Library/Developer/CommandLineTools/usr/libexec/git-core/git-http-backend",
        ]
        #else
        return [
            "/usr/lib/git-core/git-http-backend",
            "/usr/libexec/git-core/git-http-backend",
            "/usr/local/libexec/git-core/git-http-backend",
        ]
        #endif
    }

    /// Resolve `git` from PATH so `Process` doesn't need a hard-coded
    /// absolute path. Falls back to a few common Windows locations.
    private static func findGit() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        #if os(Windows)
        let sep: Character = ";"
        let exeNames = ["git.exe"]
        #else
        let sep: Character = ":"
        let exeNames = ["git"]
        #endif
        for dir in path.split(separator: sep) {
            for name in exeNames {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.path
                }
            }
        }
        return nil
    }

    // MARK: - Routing helpers

    /// Strip the `.git` suffix from a routing segment; reject anything
    /// that doesn't end in `.git` so the smart-HTTP routes don't shadow
    /// the browse routes.
    static func stripGitSuffix(_ raw: String) throws -> String {
        guard raw.hasSuffix(".git") else {
            throw BackendError.invalidName(raw)
        }
        let stripped = String(raw.dropLast(4))
        guard RepositoryService.validateSegment(stripped) else {
            throw BackendError.invalidName(raw)
        }
        return stripped
    }

    // MARK: - Core dispatch

    /// Run `git http-backend` for one request. Returns the parsed CGI
    /// response. Blocking; route handlers must call this off the event
    /// loop via `Application.threadPool.runIfActive(...)`.
    func dispatch(
        method: String,
        user: String,
        repo: String,
        pathInfoSuffix: String,    // e.g. "info/refs" or "git-upload-pack"
        queryString: String,
        contentType: String?,
        body: Data,
        pushedBy: String? = nil
    ) throws -> Response {
        // 1. Validate name segments (defense in depth on top of the
        // strip-suffix check at the route boundary).
        guard RepositoryService.validateSegment(user),
              RepositoryService.validateSegment(repo) else {
            throw BackendError.invalidName("\(user)/\(repo)")
        }
        // 2. Refuse push if not explicitly enabled.
        if pathInfoSuffix == "git-receive-pack",
           (queryString.contains("service=git-receive-pack") || method == "POST") {
            guard allowPush else { throw BackendError.pushDisabled }
        }
        if queryString.contains("service=git-receive-pack") {
            guard allowPush else { throw BackendError.pushDisabled }
        }
        // 3. Repo must exist on disk.
        let repoDir = root.appendingPathComponent(user).appendingPathComponent("\(repo).git")
        guard FileManager.default.fileExists(atPath: repoDir.path) else {
            throw BackendError.notFound(user: user, repo: repo)
        }

        // 4. Spawn git-http-backend with CGI env vars.
        let process = Process()
        process.executableURL = backend
        process.arguments = []

        let pathInfo = "/\(user)/\(repo).git/\(pathInfoSuffix)"
        // Augment PATH with the directories shipped alongside the
        // resolved git-http-backend so spawned hook scripts can find
        // `sh`, `curl`, etc. The default Windows install of Git only
        // adds `C:\Program Files\Git\cmd` to PATH; without `usr\bin`
        // and `mingw64\bin` on the inherited PATH, server-side hook
        // scripts (`#!/bin/sh`) silently fail and git-receive-pack
        // reports an opaque "pre-receive hook declined". The fix is
        // benign on POSIX hosts: the extra entries are also where
        // POSIX `sh`/`curl` typically live anyway.
        var pathParts: [String] = []
        let resolvedBackend = backend.path
        let separator: String
        #if os(Windows)
        separator = ";"
        #else
        separator = ":"
        #endif
        // Walk up from `<git-install>/...libexec/git-core/git-http-backend(.exe)`
        // to `<git-install>`, then add the typical posix sibling dirs.
        var dir = (resolvedBackend as NSString).deletingLastPathComponent
        for _ in 0..<6 {
            dir = (dir as NSString).deletingLastPathComponent
            let usrBin    = (dir as NSString).appendingPathComponent("usr/bin")
            let mingwBin  = (dir as NSString).appendingPathComponent("mingw64/bin")
            let mingw32   = (dir as NSString).appendingPathComponent("mingw32/bin")
            for candidate in [usrBin, mingwBin, mingw32] {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
                   isDir.boolValue,
                   !pathParts.contains(candidate) {
                    pathParts.append(candidate)
                }
            }
            if dir.isEmpty || dir == "/" { break }
        }
        if let inherited = ProcessInfo.processInfo.environment["PATH"], !inherited.isEmpty {
            pathParts.append(inherited)
        }
        var env: [String: String] = [
            "GIT_PROJECT_ROOT":   root.path,
            "GIT_HTTP_EXPORT_ALL": "1",
            "PATH_INFO":          pathInfo,
            "REQUEST_METHOD":     method,
            "QUERY_STRING":       queryString,
            // Make sure git-http-backend itself can find git in PATH,
            // plus the POSIX-tool sibling dirs so hook scripts work.
            "PATH": pathParts.joined(separator: separator),
        ]
        if let contentType, !contentType.isEmpty {
            env["CONTENT_TYPE"] = contentType
        }
        if !body.isEmpty {
            env["CONTENT_LENGTH"] = String(body.count)
        }
        // Tell git-http-backend to allow upload-pack + receive-pack from the
        // repo config side. Without these, the CGI helper requires the repo
        // owner to have explicitly set `http.uploadpack`/`http.receivepack`
        // in the repo's config -- a friction we don't want to push onto
        // every repo placed under GITEAX_ROOT. upload-pack is always on;
        // receive-pack is only on when GITEAX_ALLOW_PUSH=1.
        env["GIT_CONFIG_COUNT"] = allowPush ? "2" : "1"
        env["GIT_CONFIG_KEY_0"]   = "http.uploadpack"
        env["GIT_CONFIG_VALUE_0"] = "true"
        if allowPush {
            env["GIT_CONFIG_KEY_1"]   = "http.receivepack"
            env["GIT_CONFIG_VALUE_1"] = "true"
        }
        // Propagate the authenticated push user into the hook process
        // env so the per-repo pre-receive hook can identify the pusher
        // (otherwise the hook defaults to "(local)", which the
        // pre-receive ACL treats as admin -- bypassing branch
        // protection on HTTP pushes). SSH already sets this var the
        // same way (Phase 15b).
        if let pushedBy, !pushedBy.isEmpty {
            env["GITEAX_HOOK_USER"] = pushedBy
        }
        // Required for git-http-backend's process spawning (especially on
        // Windows) to inherit a sane environment.
        #if os(Windows)
        for key in ["SYSTEMROOT", "WINDIR", "TEMP", "TMP", "COMSPEC",
                    "USERPROFILE", "APPDATA", "LOCALAPPDATA"] {
            if let v = ProcessInfo.processInfo.environment[key] {
                env[key] = v
            }
        }
        #endif
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write body, then close stdin so the backend sees EOF.
        if !body.isEmpty {
            stdinPipe.fileHandleForWriting.write(body)
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Drain stdout + stderr off concurrent threads so a slow writer
        // on one side can't deadlock us on the other.
        let outData: Data
        let errData: Data
        do {
            outData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            outData = Data()
        }
        do {
            errData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            errData = Data()
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? "<binary>"
            throw BackendError.backendFailed(
                exitCode: process.terminationStatus,
                stderr: msg.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return try Self.parseCGI(outData)
    }

    // MARK: - CGI parser

    /// Split a CGI response into headers + body. CGI uses CRLF line
    /// endings between headers and a single blank line as the
    /// header/body separator. We accept both CRLF and LF for tolerance.
    static func parseCGI(_ data: Data) throws -> Response {
        let sepCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])  // \r\n\r\n
        let sepLF   = Data([0x0A, 0x0A])              // \n\n
        let (headerEnd, sepLen): (Data.Index, Int)
        if let r = data.range(of: sepCRLF) {
            headerEnd = r.lowerBound
            sepLen = sepCRLF.count
        } else if let r = data.range(of: sepLF) {
            headerEnd = r.lowerBound
            sepLen = sepLF.count
        } else {
            throw BackendError.cgiParseFailed("no header/body separator")
        }
        let headerBlock = data[..<headerEnd]
        let bodyStart = data.index(headerEnd, offsetBy: sepLen)
        let body = data[bodyStart...]
        guard let headerString = String(data: headerBlock, encoding: .utf8) else {
            throw BackendError.cgiParseFailed("headers not UTF-8")
        }

        var headers = HTTPHeaders()
        var status: HTTPResponseStatus = .ok
        for rawLine in headerString.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty { continue }
            // CGI may use a "Status: 404 Not Found" header to override
            // the default 200. Handle that and skip non-HTTP headers.
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if name.lowercased() == "status" {
                    // "404 Not Found" -> 404
                    if let space = value.firstIndex(of: " "),
                       let code = Int(value[..<space]) {
                        status = HTTPResponseStatus(statusCode: code)
                    } else if let code = Int(value) {
                        status = HTTPResponseStatus(statusCode: code)
                    }
                    continue
                }
                headers.add(name: name, value: value)
            }
        }
        return Response(status: status, headers: headers, body: Data(body))
    }
}
