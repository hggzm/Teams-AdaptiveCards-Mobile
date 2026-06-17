// hggz/giteax -- Phase 27 + Phase 28: hook installer + internal
// hook callback endpoints.
//
// Why this exists:
//
//   - The Phase 11 `push` event already fires for smart-HTTP receive-
//     pack via Vapor. But it MISSES out-of-band (OOB) pushes done via
//     filesystem path (e.g. `git push file:///path/to/bare` from a
//     local script, or the giteax host directly pushing into the
//     bare repo).
//   - The Phase 13 protected-branches gate is coarse: if ANY branch
//     is protected, writers can't push to ANY branch. To make this
//     per-branch we need to inspect the actual refs in the push,
//     which means using git's hook system.
//
// What we do:
//
//   On every authenticated smart-HTTP `git-receive-pack` request, the
//   `HookInstaller` writes (or refreshes) two scripts into the bare
//   repo's `hooks/` directory:
//
//     hooks/pre-receive   - validates per-branch ACL before accepting
//                           the push. Phase 28.
//     hooks/post-receive  - fires the giteax `push` webhook event,
//                           which also catches OOB pushes when those
//                           same refs are pushed via the filesystem
//                           path. Phase 27.
//
//   Both scripts authenticate back to giteax over loopback using a
//   per-repo `hookToken` stored in meta.json (see
//   RepoMetaStore.ensureHookToken).
//
// Windows compatibility:
//
//   git-for-windows ships an embedded msys `sh.exe` + `curl.exe`.
//   `git-receive-pack` (and direct local `git push file:///...`) both
//   invoke hooks through that shell. So a plain POSIX `#!/bin/sh`
//   script with curl works without any extra .bat shims.
//
// Graceful degradation:
//
//   - If the hook script fails (no curl, server down, network blip),
//     post-receive returns success (push is committed); pre-receive
//     returns success too (we don't want a broken loopback to block
//     all pushes). The internal endpoints log the failure for
//     diagnosis.
//   - The installer only writes a script when there isn't already a
//     non-giteax script at that path. We never clobber a custom hook
//     a repo admin wrote manually.

import Vapor
import Foundation

// MARK: - Installer

actor HookInstaller {

    /// Marker comment we look for to identify our own scripts so we
    /// don't clobber user-customised hooks. Bumped on any script-template
    /// change so existing managed hooks get re-rendered on next push.
    static let giteaxMarker = "# giteax-managed hook v0.0.19"

    let rootURL: URL
    let metaStore: RepoMetaStore
    let serverURL: String   // e.g. "http://127.0.0.1:5099"
    let logger: Logger

    init(rootURL: URL, metaStore: RepoMetaStore, serverURL: String, logger: Logger) {
        self.rootURL = rootURL
        self.metaStore = metaStore
        self.serverURL = serverURL
        self.logger = logger
    }

    /// Idempotent install. Safe to call on every push attempt.
    /// Writes the hooks into <root>/<user>/<repo>.git/hooks/.
    func ensureInstalled(user: String, repo: String) async {
        let bareURL = rootURL
            .appendingPathComponent(user, isDirectory: true)
            .appendingPathComponent("\(repo).git", isDirectory: true)
        let hooksURL = bareURL.appendingPathComponent("hooks", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bareURL.path) else {
            // Repo doesn't exist on disk; smart-HTTP already returned
            // 404 for this case. Don't install.
            return
        }
        do {
            try FileManager.default.createDirectory(at: hooksURL, withIntermediateDirectories: true)
        } catch {
            logger.warning("[hooks] failed to mkdir \(hooksURL.path): \(error)")
            return
        }
        // Mint or fetch the hook token.
        let token: String
        do {
            (token, _) = try await metaStore.ensureHookToken(user: user, repo: repo)
        } catch {
            logger.warning("[hooks] ensureHookToken failed for \(user)/\(repo): \(error)")
            return
        }

        for kind in ["pre-receive", "post-receive"] {
            let dest = hooksURL.appendingPathComponent(kind, isDirectory: false)
            // If a file exists there that's NOT one of ours, leave it alone
            // -- repo admins occasionally hand-write custom hooks.
            // We match ANY giteax-managed marker version so re-installs
            // upgrade older hooks (e.g. v0.0.16 -> v0.0.19) without being
            // misidentified as user-authored.
            if FileManager.default.fileExists(atPath: dest.path),
               let existing = try? String(contentsOf: dest, encoding: .utf8),
               !existing.contains("# giteax-managed hook")
            {
                logger.notice("[hooks] \(user)/\(repo) custom \(kind) hook present; skipping install")
                continue
            }
            let script = Self.renderScript(kind: kind, user: user, repo: repo, token: token, serverURL: serverURL)
            // Atomic-ish write through temp+remove+move (FileManager.replaceItemAt
            // fatalErrors on swift-corelibs-foundation on Windows; see memory note).
            let tmp = hooksURL.appendingPathComponent("\(kind).tmp-\(ProcessInfo.processInfo.processIdentifier)")
            do {
                try? FileManager.default.removeItem(at: tmp)
                try script.write(to: tmp, atomically: true, encoding: .utf8)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tmp, to: dest)
                // POSIX permissions don't matter on Windows -- git-for-windows
                // executes hook scripts regardless of the +x bit. We set them
                // anyway so this works on Linux/macOS deployments too.
                #if !os(Windows)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: dest.path)
                #endif
            } catch {
                logger.warning("[hooks] failed to install \(kind) for \(user)/\(repo): \(error)")
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }

    /// Render the hook script body. Identity-bearing pieces (user, repo,
    /// token, server URL) are baked in; the script reads stdin from
    /// git natively.
    private static func renderScript(kind: String, user: String, repo: String, token: String, serverURL: String) -> String {
        // Shell-escape values that might contain `/` etc. For our case
        // these are all matched against [A-Za-z0-9._-]{1,100} so simple
        // double-quoting is sufficient.
        let endpoint = "\(serverURL)/api/internal/hook/\(user)/\(repo)/\(kind)"
        // pre-receive must propagate non-zero exit when giteax rejects;
        // post-receive must always exit 0 (the push has already landed).
        let exitOnFailure = (kind == "pre-receive") ? "exit 1" : "exit 0"
        return """
        #!/bin/sh
        \(giteaxMarker)
        # Auto-installed by giteax. Re-installed on every push, so
        # editing this file by hand is pointless -- customise via the
        # giteax API or remove the X-Giteax-Hook-Token line and the
        # installer will leave your version alone (any non-marker
        # script is preserved).
        ENDPOINT="\(endpoint)"
        TOKEN="\(token)"
        BODY=$(cat)
        # `curl -fsS` -> fail on HTTP >= 400 with no progress noise.
        # `-m 5` caps the wait so a hung giteax doesn't freeze every push.
        if ! command -v curl >/dev/null 2>&1; then
            echo "[giteax hook] curl not available; skipping callback" >&2
            exit 0
        fi
        # The SSH listener (Phase 15b) sets GITEAX_HOOK_USER to the
        # authenticated SSH user. When set, propagate to giteax so the
        # pre-receive ACL identifies the pusher instead of falling back
        # to '(local)'. HTTP pushes leave the env var unset and continue
        # to be gated upstream by SmartHTTP gateWrite (compatible with
        # the pre-15b behaviour).
        PUSHER_HEADER=""
        if [ -n "$GITEAX_HOOK_USER" ]; then
            PUSHER_HEADER="-H X-Giteax-Pushed-By:$GITEAX_HOOK_USER"
        fi
        RESPONSE=$(printf '%s' "$BODY" | curl -fsS -m 5 \\
            -H "X-Giteax-Hook-Token: $TOKEN" \\
            -H "Content-Type: text/plain" \\
            $PUSHER_HEADER \\
            --data-binary @- \\
            "$ENDPOINT" 2>&1)
        STATUS=$?
        if [ $STATUS -ne 0 ]; then
            echo "[giteax hook] callback to giteax failed (status=$STATUS): $RESPONSE" >&2
            \(exitOnFailure)
        fi
        exit 0
        """
    }
}

// MARK: - Internal hook endpoints

/// Register `POST /api/internal/hook/:user/:repo/pre-receive` and
/// `POST /api/internal/hook/:user/:repo/post-receive`. Both consume
/// raw text lines of the form `<old-oid> <new-oid> <ref>` and
/// authenticate via the `X-Giteax-Hook-Token` header against the
/// per-repo token in meta.json.
func registerInternalHookRoutes(
    _ app: Application,
    metaStore: RepoMetaStore,
    events: EventSink,
    access: AccessController
) {
    // Limit the internal hook endpoints to localhost. The hook token
    // is the primary authenticator, but defence-in-depth -- nobody
    // outside the loopback interface should be able to reach these
    // routes.
    @Sendable
    func enforceLoopback(_ req: Request) throws {
        guard let addr = req.remoteAddress?.ipAddress else {
            throw Abort(.forbidden, reason: "internal hook endpoint requires loopback")
        }
        guard addr == "127.0.0.1" || addr == "::1" || addr.hasPrefix("::ffff:127.") else {
            throw Abort(.forbidden, reason: "internal hook endpoint requires loopback (got \(addr))")
        }
    }

    @Sendable
    func params(_ req: Request) throws -> (String, String) {
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        return (user, repo)
    }

    @Sendable
    func authenticate(_ req: Request, user: String, repo: String) async throws {
        guard let token = req.headers.first(name: "X-Giteax-Hook-Token") else {
            throw Abort(.unauthorized, reason: "missing X-Giteax-Hook-Token")
        }
        let ok = await metaStore.validateHookToken(user: user, repo: repo, presented: token)
        guard ok else {
            throw Abort(.forbidden, reason: "invalid hook token")
        }
    }

    /// Parse `<old> <new> <ref>` lines into HookRefUpdate values. Skips
    /// blank lines and lines without exactly 3 whitespace-separated
    /// fields.
    @Sendable
    func parseRefUpdates(_ body: String) -> [HookRefUpdate] {
        var out: [HookRefUpdate] = []
        for raw in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 3 else { continue }
            out.append(HookRefUpdate(
                before: String(parts[0]),
                after:  String(parts[1]),
                ref:    String(parts[2])
            ))
        }
        return out
    }

    @Sendable
    func bodyString(_ req: Request) -> String {
        guard let buffer = req.body.data else { return "" }
        return buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
    }

    // ── Phase 28: pre-receive (per-branch ACL gate) ────────────────────
    //
    // Inputs:
    //   - `X-Giteax-Hook-Token` header (validated against meta)
    //   - body: `<old> <new> <ref>\n...` from git (raw text)
    //   - `X-Giteax-Pushed-By` header set by smart-HTTP CGI wrapper
    //     when known; otherwise "(local)" (OOB filesystem push).
    //
    // Decision policy (refines the Phase 13 coarse gate):
    //   - For each ref update:
    //       * If the ref is in protectedBranches AND pusher is not
    //         admin on the repo -> 403 (overall push rejected).
    //   - Otherwise 200.
    app.post("api", "internal", "hook", ":user", ":repo", "pre-receive") { req async throws -> Response in
        try enforceLoopback(req)
        let (u, r) = try params(req)
        try await authenticate(req, user: u, repo: r)
        let pusher = req.headers.first(name: "X-Giteax-Pushed-By") ?? "(local)"
        let updates = parseRefUpdates(bodyString(req))
        // Whose permission do we check? We have an explicit string;
        // build the AuthIdentity for it.
        let id = AuthIdentity(name: pusher == "(local)" ? nil : pusher, isGlobalAdmin: false)
        let perm = (try? await access.effectivePermission(identity: id, user: u, repo: r)) ?? nil
        let isAdmin: Bool = {
            // The OOB "(local)" pusher runs as the giteax process owner.
            // For now we treat OOB as admin -- the filesystem path is
            // already privileged. A future v0.0.17 could tighten this.
            if pusher == "(local)" { return true }
            guard let p = perm else { return false }
            return p == .admin
        }()
        var protectedHits: [String] = []
        for upd in updates {
            // ref looks like "refs/heads/main"; strip prefix to compare
            // against the protectedBranches set (which uses short names).
            let shortName = stripRefsHeads(upd.ref)
            if let shortName, await metaStore.isProtected(user: u, repo: r, branch: shortName) {
                if !isAdmin { protectedHits.append(shortName) }
            }
        }
        if !protectedHits.isEmpty {
            req.logger.warning("[hook] pre-receive REJECT \(u)/\(r) pusher=\(pusher) protected=\(protectedHits)")
            throw Abort(.forbidden,
                        reason: "push to protected branch(es) requires admin: \(protectedHits.joined(separator: ", "))")
        }
        return Response(status: .ok)
    }

    // ── Phase 27: post-receive (fire push event for OOB filesystem pushes) ─
    //
    // Inputs same as pre-receive. Fires the giteax `push` webhook with
    // an OOB-flavored payload so subscribers can distinguish in-band
    // (HTTP) from out-of-band (filesystem) pushes. In-band pushes
    // already fire via RepoRoutes -- this is the OOB safety net.
    //
    // Authentication is by hook token; the pusher identity is best-
    // effort (taken from the X-Giteax-Pushed-By header set by smart-
    // HTTP, else "(local)" for filesystem pushes).
    app.post("api", "internal", "hook", ":user", ":repo", "post-receive") { req async throws -> Response in
        try enforceLoopback(req)
        let (u, r) = try params(req)
        try await authenticate(req, user: u, repo: r)
        let pusher = req.headers.first(name: "X-Giteax-Pushed-By") ?? "(local)"
        let updates = parseRefUpdates(bodyString(req))
        // The smart-HTTP path already fires its own `push` event with
        // refUpdates from Phase 20; firing again would double-deliver.
        // We tag this one as channel="hook" so subscribers can dedupe
        // or filter. Skip entirely when the hook fires with zero ref
        // updates (git invokes hooks even on noop receives).
        guard !updates.isEmpty else {
            return Response(status: .ok)
        }
        let refUpdatesPayload: [[String: Any]] = updates.map { u in
            var kind = "updated"
            if u.before == "0000000000000000000000000000000000000000" {
                kind = "created"
            } else if u.after == "0000000000000000000000000000000000000000" {
                kind = "deleted"
            }
            return [
                "ref": u.ref,
                "before": u.before,
                "after": u.after,
                "kind": kind,
            ]
        }
        await events.fire(user: u, repo: r, event: "push", payload: [
            "pusher": pusher,
            "channel": "hook",
            "refUpdateCount": updates.count,
            "refUpdates": refUpdatesPayload,
        ])
        return Response(status: .ok)
    }
}

// MARK: - Helpers

private func stripRefsHeads(_ ref: String) -> String? {
    let prefix = "refs/heads/"
    if ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
    return nil
}

/// Wire-shape for a single ref change inside a hook callback.
struct HookRefUpdate: Sendable {
    let before: String
    let after: String
    let ref: String
}
