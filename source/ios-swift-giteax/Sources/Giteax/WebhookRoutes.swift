import Foundation
import Vapor

/// Phase 11 wiring: webhook CRUD + delivery history + manual test ping.
///
///   GET    /api/repos/:user/:repo/hooks                  (auth)  list
///   POST   /api/repos/:user/:repo/hooks                  (auth)  create
///   GET    /api/repos/:user/:repo/hooks/:id              (auth)  single
///   PATCH  /api/repos/:user/:repo/hooks/:id              (auth)  update
///   DELETE /api/repos/:user/:repo/hooks/:id              (auth)  remove
///   GET    /api/repos/:user/:repo/hooks/:id/deliveries   (auth)  delivery log
///   POST   /api/repos/:user/:repo/hooks/:id/test         (auth)  fires a `ping`
///   GET    /api/repos/:user/:repo/hooks/deliveries       (auth)  all deliveries (all hooks)
///
/// All webhook routes require HTTP Basic auth -- hook configuration is
/// administrative, not browse data. Same gate as push / issues / PRs.
func registerWebhookRoutes(
    _ app: Application,
    store: WebhookStore,
    dispatcher: WebhookDispatcher?,
    pushAuth: GitPushBasicAuth?,
    access: AccessController? = nil
) {
    @Sendable
    func requireAuthor(_ req: Request, user: String, repo: String) async throws -> String {
        guard let pushAuth else {
            throw Abort(.forbidden, reason: "webhook config is disabled (set GITEAX_ALLOW_PUSH=1 and create a user)")
        }
        if let response = try await pushAuth.gate(req) {
            _ = response
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
            throw Abort(.unauthorized, headers: headers, reason: "authentication required for webhook config")
        }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        // Phase 12: webhook management requires repo admin.
        if let access {
            do {
                try await access.require(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    atLeast: .admin, user: user, repo: repo,
                    scope: "managing webhooks"
                )
            } catch let e as AccessController.AccessError {
                throw Abort(e.status, headers: e.headers, reason: e.reason)
            }
        }
        return name
    }

    app.get("api", "repos", ":user", ":repo", "hooks") { req async throws -> Response in
        let (u, r) = try whRepoParams(req)
        _ = try await requireAuthor(req, user: u, repo: r)
        let hooks: [WebhookStore.Hook]
        do {
            hooks = try await store.list(user: u, repo: r)
        } catch let e as WebhookStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try whJSON(HookListDTO(user: u, repo: r, count: hooks.count, hooks: hooks.map(HookDTO.from)))
    }

    app.post("api", "repos", ":user", ":repo", "hooks") { req async throws -> Response in
        let (u, r) = try whRepoParams(req)
        _ = try await requireAuthor(req, user: u, repo: r)
        let body = try req.content.decode(CreateHookDTO.self)
        let h: WebhookStore.Hook
        do {
            h = try await store.create(
                user: u, repo: r,
                url: body.url,
                secret: body.secret,
                events: body.events,
                active: body.active ?? true,
                branchPatterns: body.branchPatterns,
                rateLimitPerMinute: body.rateLimitPerMinute
            )
        } catch let e as WebhookStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try whJSON(HookDTO.from(h), status: .created)
    }

    app.get("api", "repos", ":user", ":repo", "hooks", ":id") { req async throws -> Response in
        let (u, r, id) = try whHookParams(req)
        _ = try await requireAuthor(req, user: u, repo: r)
        let h: WebhookStore.Hook
        do {
            h = try await store.get(user: u, repo: r, id: id)
        } catch let e as WebhookStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try whJSON(HookDTO.from(h))
    }

    app.patch("api", "repos", ":user", ":repo", "hooks", ":id") { req async throws -> Response in
        let (u, r, id) = try whHookParams(req)
        _ = try await requireAuthor(req, user: u, repo: r)
        let body = try req.content.decode(UpdateHookDTO.self)
        let h: WebhookStore.Hook
        do {
            h = try await store.update(
                user: u, repo: r, id: id,
                url: body.url, secret: body.secret,
                events: body.events, active: body.active,
                branchPatterns: body.branchPatterns,
                rateLimitPerMinute: body.rateLimitPerMinute
            )
        } catch let e as WebhookStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try whJSON(HookDTO.from(h))
    }

    app.delete("api", "repos", ":user", ":repo", "hooks", ":id") { req async throws -> Response in
        let (u, r, id) = try whHookParams(req)
        _ = try await requireAuthor(req, user: u, repo: r)
        do {
            try await store.delete(user: u, repo: r, id: id)
        } catch let e as WebhookStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return Response(status: .noContent)
    }

    app.get("api", "repos", ":user", ":repo", "hooks", ":id", "deliveries") { req async throws -> Response in
        let (u, r, id) = try whHookParams(req)
        _ = try await requireAuthor(req, user: u, repo: r)
        let limit = clampWHInt(Int(req.query[String.self, at: "limit"] ?? "") ?? 50, min: 1, max: 200)
        let ds: [WebhookStore.Delivery]
        do {
            ds = try await store.deliveries(user: u, repo: r, hookID: id, limit: limit)
        } catch let e as WebhookStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try whJSON(DeliveryListDTO(user: u, repo: r, hookID: id, count: ds.count, deliveries: ds.map(DeliveryDTO.from)))
    }

    app.get("api", "repos", ":user", ":repo", "hooks-deliveries") { req async throws -> Response in
        let (u, r) = try whRepoParams(req)
        _ = try await requireAuthor(req, user: u, repo: r)
        let limit = clampWHInt(Int(req.query[String.self, at: "limit"] ?? "") ?? 50, min: 1, max: 200)
        let ds: [WebhookStore.Delivery]
        do {
            ds = try await store.deliveries(user: u, repo: r, hookID: nil, limit: limit)
        } catch let e as WebhookStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try whJSON(DeliveryListDTO(user: u, repo: r, hookID: nil, count: ds.count, deliveries: ds.map(DeliveryDTO.from)))
    }

    /// Send a synthetic `ping` event to a single hook. Useful for sanity-
    /// checking a receiver URL right after configuring it.
    app.post("api", "repos", ":user", ":repo", "hooks", ":id", "test") { req async throws -> Response in
        let (u, r, id) = try whHookParams(req)
        let author = try await requireAuthor(req, user: u, repo: r)
        let _ = try await store.get(user: u, repo: r, id: id)   // 404 if missing
        if let dispatcher {
            await dispatcher.fire(user: u, repo: r, event: "ping", payload: [
                "kind": "manual-test",
                "triggeredBy": author,
                "hookID": id,
            ])
        }
        return try whJSON(["status": "queued", "event": "ping", "hookID": id] as [String: Any])
    }

    /// Phase 13/21: replay a previously-delivered event to the same hook.
    /// If the original delivery still has its payload body persisted
    /// (<= 64 KiB) we replay it verbatim. Otherwise we fall back to a
    /// synthetic `ping` referencing the original delivery -- enough to
    /// confirm the receiver is still reachable + authenticating.
    app.post("api", "repos", ":user", ":repo", "hooks", ":id", "deliveries", ":deliveryID", "redeliver") { req async throws -> Response in
        let (u, r, id) = try whHookParams(req)
        guard let deliveryID = req.parameters.get("deliveryID", as: Int.self) else {
            throw Abort(.badRequest, reason: "missing :deliveryID")
        }
        let author = try await requireAuthor(req, user: u, repo: r)
        // 404 check on hook itself.
        let hook = try await store.get(user: u, repo: r, id: id)
        // 404 check on the delivery.
        let deliveries = try await store.deliveries(user: u, repo: r, hookID: id, limit: 200)
        guard let original = deliveries.first(where: { $0.id == deliveryID }) else {
            throw Abort(.notFound, reason: "delivery #\(deliveryID) not found for hook #\(id)")
        }
        let exact: Bool
        if let dispatcher {
            if let body = original.body, !body.isEmpty {
                dispatcher.deliverOne(
                    hook: hook,
                    user: u, repo: r,
                    event: original.event,
                    body: body
                )
                exact = true
            } else {
                await dispatcher.fire(user: u, repo: r, event: "ping", payload: [
                    "kind": "manual-redeliver",
                    "triggeredBy": author,
                    "hookID": id,
                    "originalDeliveryID": deliveryID,
                    "originalEvent": original.event,
                    "note": "payload body not persisted (legacy/oversized delivery); synthetic ping",
                ])
                exact = false
            }
        } else {
            exact = false
        }
        return try whJSON([
            "status": "queued",
            "event": exact ? original.event : "ping",
            "kind": exact ? "manual-redeliver-exact" : "manual-redeliver-synthetic",
            "hookID": id,
            "originalDeliveryID": deliveryID,
            "exact": exact,
        ] as [String: Any], status: .accepted)
    }
}

// MARK: - DTOs

private struct CreateHookDTO: Content {
    let url: String
    let secret: String?
    let events: [String]
    let active: Bool?
    /// Phase 23: optional glob list against short branch names.
    let branchPatterns: [String]?
    /// Phase 24: optional per-minute attempt cap.
    let rateLimitPerMinute: Int?
}

private struct UpdateHookDTO: Content {
    let url: String?
    let secret: String?
    let events: [String]?
    let active: Bool?
    let branchPatterns: [String]?
    let rateLimitPerMinute: Int?
}

private struct HookDTO: Content {
    let id: Int
    let url: String
    let hasSecret: Bool
    let events: [String]
    let active: Bool
    let createdAt: Date
    let lastDeliveredAt: Date?
    let lastStatus: Int?
    let branchPatterns: [String]?
    let rateLimitPerMinute: Int?

    static func from(_ h: WebhookStore.Hook) -> HookDTO {
        HookDTO(
            id: h.id,
            url: h.url,
            hasSecret: h.secret != nil && !(h.secret ?? "").isEmpty,
            events: h.events,
            active: h.active,
            createdAt: h.createdAt,
            lastDeliveredAt: h.lastDeliveredAt,
            lastStatus: h.lastStatus,
            branchPatterns: h.branchPatterns,
            rateLimitPerMinute: h.rateLimitPerMinute
        )
    }
}

private struct HookListDTO: Content {
    let user: String
    let repo: String
    let count: Int
    let hooks: [HookDTO]
}

private struct DeliveryDTO: Content {
    let id: Int
    let hookID: Int
    let event: String
    let url: String
    let attempts: Int
    let lastStatus: Int?
    let lastError: String?
    let deliveredAt: Date
    let durationMs: Int
    /// Phase 21: indicates the original payload is persisted (<= 64 KiB)
    /// and the delivery can be exact-replayed via the redeliver endpoint.
    /// We don't expose the raw bytes through this endpoint to keep the
    /// list cheap and avoid leaking large payloads on simple GETs.
    let bodyPersisted: Bool
    let bodySize: Int

    static func from(_ d: WebhookStore.Delivery) -> DeliveryDTO {
        DeliveryDTO(
            id: d.id, hookID: d.hookID, event: d.event, url: d.url,
            attempts: d.attempts, lastStatus: d.lastStatus,
            lastError: d.lastError, deliveredAt: d.deliveredAt,
            durationMs: d.durationMs,
            bodyPersisted: d.body != nil,
            bodySize: d.body?.count ?? 0
        )
    }
}

private struct DeliveryListDTO: Content {
    let user: String
    let repo: String
    let hookID: Int?
    let count: Int
    let deliveries: [DeliveryDTO]
}

// MARK: - Helpers

private func whRepoParams(_ req: Request) throws -> (String, String) {
    guard let user = req.parameters.get("user"),
          let repo = req.parameters.get("repo")
    else { throw Abort(.badRequest, reason: "missing :user or :repo") }
    return (user, repo)
}

private func whHookParams(_ req: Request) throws -> (String, String, Int) {
    guard let user = req.parameters.get("user"),
          let repo = req.parameters.get("repo"),
          let id = req.parameters.get("id", as: Int.self)
    else { throw Abort(.badRequest, reason: "missing :user, :repo or :id") }
    return (user, repo, id)
}

private func whJSON<E: Encodable>(_ value: E, status: HTTPResponseStatus = .ok) throws -> Response {
    let r = Response(status: status)
    try r.content.encode(value, as: .json)
    return r
}

/// Specialised JSON for `[String: Any]` payloads (the test endpoint
/// returns a small dynamic object, easier than defining a one-off DTO).
private func whJSON(_ dict: [String: Any], status: HTTPResponseStatus = .ok) throws -> Response {
    let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    let r = Response(status: status)
    r.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
    r.body = .init(data: data)
    return r
}

private func clampWHInt(_ x: Int, min lo: Int, max hi: Int) -> Int {
    if x < lo { return lo }
    if x > hi { return hi }
    return x
}
