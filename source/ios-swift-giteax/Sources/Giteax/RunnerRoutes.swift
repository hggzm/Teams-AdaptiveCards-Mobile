import Foundation
import Vapor

/// Phase 39: Gitea Actions-style runner + job HTTP API.
///
///  Runner registry (admin-token-gated, Bearer GITEAX_ADMIN_TOKEN):
///
///      POST   /api/admin/runners              {name, labels?}        -> 201 {id, name, token, labels[]}
///      GET    /api/admin/runners              -> {count, runners[]}
///      DELETE /api/admin/runners/:id          -> 204
///
///  Job lifecycle (per-repo, ACL-gated):
///
///      POST   /api/repos/:u/:r/actions/jobs   {workflow, ref, payload?, labels?}   write+
///      GET    /api/repos/:u/:r/actions/jobs   ?state=queued|running|...           read
///      GET    /api/repos/:u/:r/actions/jobs/:id                                   read
///      POST   /api/repos/:u/:r/actions/jobs/:id/cancel                            write+
///
///  Runner endpoints (Bearer giteax_runner_<token>):
///
///      GET    /api/runners/jobs               -> 204 if none, 200 + claimed Job otherwise
///      POST   /api/runners/jobs/:id/status    {state, output?, exitCode?}
///
/// Every state transition fires a `workflow_run` webhook event for the
/// affected repository (action ∈ {queued, running, success, failure, cancelled}).
func registerRunnerRoutes(
    _ app: Application,
    runners: RunnerStore,
    jobs: JobStore,
    pushAuth: GitPushBasicAuth?,
    events: EventSink = DiscardEventSink(),
    access: AccessController? = nil,
    adminToken: String?
) {
    // MARK: - Admin: runner registry

    struct AdminBearer: AsyncMiddleware {
        let expected: String
        func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            guard let raw = req.headers.bearerAuthorization?.token, raw == expected else {
                throw Abort(.unauthorized, reason: "admin token required")
            }
            return try await next.respond(to: req)
        }
    }

    if let adminToken {
        let admin = app.grouped(AdminBearer(expected: adminToken))

        admin.post("api", "admin", "runners") { req async throws -> Response in
            let body = try req.content.decode(RegisterRunnerDTO.self)
            let registeredBy: String = req.headers.first(name: "X-Giteax-Admin-As") ?? "(admin)"
            do {
                let (runner, plaintext) = try await runners.register(
                    name: body.name,
                    labels: body.labels ?? [],
                    registeredBy: registeredBy
                )
                let dto = RegisteredRunnerDTO(
                    id: runner.id, name: runner.name,
                    token: plaintext, labels: runner.labels,
                    createdAt: runner.createdAt
                )
                let resp = Response(status: .created)
                try resp.content.encode(dto, as: .json)
                return resp
            } catch let e as RunnerStore.StoreError {
                throw Abort(e.status, reason: e.reason)
            }
        }

        admin.get("api", "admin", "runners") { req async throws -> Response in
            let list = try await runners.list()
            let dto = RunnerListDTO(
                count: list.count,
                runners: list.map(RunnerDTO.from)
            )
            let resp = Response(status: .ok)
            try resp.content.encode(dto, as: .json)
            return resp
        }

        admin.delete("api", "admin", "runners", ":id") { req async throws -> Response in
            guard let id = req.parameters.get("id", as: Int.self) else {
                throw Abort(.badRequest, reason: "missing :id")
            }
            do {
                let removed = try await runners.delete(id: id)
                if !removed { throw Abort(.notFound, reason: "no runner with id=\(id)") }
            } catch let e as RunnerStore.StoreError {
                throw Abort(e.status, reason: e.reason)
            }
            return Response(status: .noContent)
        }
    } else {
        for path in ["api/admin/runners", "api/admin/runners/:id"] {
            app.on(.POST,   path.pathComponents) { _ async throws -> Response in
                throw Abort(.serviceUnavailable, reason: "runner admin disabled (set GITEAX_ADMIN_TOKEN)")
            }
            app.on(.GET,    path.pathComponents) { _ async throws -> Response in
                throw Abort(.serviceUnavailable, reason: "runner admin disabled (set GITEAX_ADMIN_TOKEN)")
            }
            app.on(.DELETE, path.pathComponents) { _ async throws -> Response in
                throw Abort(.serviceUnavailable, reason: "runner admin disabled (set GITEAX_ADMIN_TOKEN)")
            }
        }
    }

    // MARK: - Helpers (per-repo gates)

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

    @Sendable
    func requireWriter(_ req: Request, user: String, repo: String, scope: String) async throws -> String {
        guard let pushAuth else {
            throw Abort(.forbidden, reason: "actions disabled (set GITEAX_ALLOW_PUSH=1 and create a user)")
        }
        if let _ = try await pushAuth.gate(req) {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm=\"giteax\""#)
            throw Abort(.unauthorized, headers: headers, reason: "authentication required")
        }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        if let access {
            do {
                try await access.require(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    atLeast: .write, user: user, repo: repo, scope: scope
                )
            } catch let e as AccessController.AccessError {
                throw Abort(e.status, headers: e.headers, reason: e.reason)
            }
        }
        return name
    }

    @Sendable
    func params(_ req: Request) throws -> (String, String) {
        guard let u = req.parameters.get("user"), let r = req.parameters.get("repo") else {
            throw Abort(.badRequest, reason: "missing :user/:repo")
        }
        return (u, r)
    }

    // MARK: - Per-repo job routes

    app.post("api", "repos", ":user", ":repo", "actions", "jobs") { req async throws -> Response in
        let (u, r) = try params(req)
        let who = try await requireWriter(req, user: u, repo: r, scope: "enqueueing actions jobs")
        let body = try req.content.decode(EnqueueJobDTO.self)
        let job: JobStore.Job
        do {
            job = try await jobs.enqueue(
                user: u, repo: r,
                workflow: body.workflow,
                ref: body.ref,
                payload: body.payload,
                labels: body.labels ?? [],
                requestedBy: who
            )
        } catch let e as JobStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        await events.fire(user: u, repo: r, event: "workflow_run", payload: [
            "action": "queued",
            "jobID": job.id,
            "workflow": job.workflow,
            "ref": job.ref,
            "state": job.state.rawValue,
            "requestedBy": who,
        ])
        let resp = Response(status: .created)
        try resp.content.encode(JobDTO.from(job), as: .json)
        return resp
    }

    app.get("api", "repos", ":user", ":repo", "actions", "jobs") { req async throws -> Response in
        let (u, r) = try params(req)
        try await gateRead(req, user: u, repo: r)
        let stateStr = try? req.query.get(String.self, at: "state")
        let stateFilter: JobStore.State? = stateStr.flatMap { JobStore.State(rawValue: $0) }
        let list: [JobStore.Job]
        do {
            list = try await jobs.list(user: u, repo: r, stateFilter: stateFilter)
        } catch let e as JobStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        let dto = JobListDTO(
            user: u, repo: r,
            count: list.count,
            jobs: list.map(JobDTO.from)
        )
        let resp = Response(status: .ok)
        try resp.content.encode(dto, as: .json)
        return resp
    }

    app.get("api", "repos", ":user", ":repo", "actions", "jobs", ":id") { req async throws -> Response in
        let (u, r) = try params(req)
        try await gateRead(req, user: u, repo: r)
        guard let id = req.parameters.get("id", as: Int.self) else {
            throw Abort(.badRequest, reason: "missing :id")
        }
        let job: JobStore.Job
        do {
            job = try await jobs.get(id: id)
        } catch let e as JobStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        guard job.repoUser == u && job.repoName == r else {
            throw Abort(.notFound, reason: "no job with id=\(id) in this repo")
        }
        let resp = Response(status: .ok)
        try resp.content.encode(JobDTO.from(job), as: .json)
        return resp
    }

    app.post("api", "repos", ":user", ":repo", "actions", "jobs", ":id", "cancel") { req async throws -> Response in
        let (u, r) = try params(req)
        let who = try await requireWriter(req, user: u, repo: r, scope: "cancelling actions jobs")
        guard let id = req.parameters.get("id", as: Int.self) else {
            throw Abort(.badRequest, reason: "missing :id")
        }
        // Confirm scope.
        let existing: JobStore.Job
        do {
            existing = try await jobs.get(id: id)
        } catch let e as JobStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        guard existing.repoUser == u && existing.repoName == r else {
            throw Abort(.notFound, reason: "no job with id=\(id) in this repo")
        }
        let cancelled: JobStore.Job
        do {
            cancelled = try await jobs.cancel(id: id)
        } catch let e as JobStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        await events.fire(user: u, repo: r, event: "workflow_run", payload: [
            "action": "cancelled",
            "jobID": cancelled.id,
            "workflow": cancelled.workflow,
            "ref": cancelled.ref,
            "state": cancelled.state.rawValue,
            "cancelledBy": who,
        ])
        let resp = Response(status: .ok)
        try resp.content.encode(JobDTO.from(cancelled), as: .json)
        return resp
    }

    // MARK: - Runner endpoints (token-bearer)

    @Sendable
    func authRunner(_ req: Request) async throws -> RunnerStore.Runner {
        guard let bearer = req.headers.bearerAuthorization?.token else {
            throw Abort(.unauthorized, reason: "runner token required (Bearer giteax_runner_*)")
        }
        let runner: RunnerStore.Runner?
        do { runner = try await runners.authenticate(plaintextToken: bearer) }
        catch let e as RunnerStore.StoreError { throw Abort(e.status, reason: e.reason) }
        guard let r = runner else {
            throw Abort(.unauthorized, reason: "unknown runner token")
        }
        return r
    }

    app.get("api", "runners", "jobs") { req async throws -> Response in
        let runner = try await authRunner(req)
        let claimed: JobStore.Job?
        do {
            claimed = try await jobs.claimNext(runnerID: runner.id, runnerLabels: runner.labels)
        } catch let e as JobStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        guard let job = claimed else {
            return Response(status: .noContent)
        }
        await events.fire(user: job.repoUser, repo: job.repoName, event: "workflow_run", payload: [
            "action": "running",
            "jobID": job.id,
            "workflow": job.workflow,
            "ref": job.ref,
            "state": job.state.rawValue,
            "runnerID": runner.id,
            "runnerName": runner.name,
        ])
        let resp = Response(status: .ok)
        try resp.content.encode(JobDTO.from(job), as: .json)
        return resp
    }

    app.post("api", "runners", "jobs", ":id", "status") { req async throws -> Response in
        let runner = try await authRunner(req)
        guard let id = req.parameters.get("id", as: Int.self) else {
            throw Abort(.badRequest, reason: "missing :id")
        }
        let body = try req.content.decode(JobStatusDTO.self)
        guard let state = JobStore.State(rawValue: body.state) else {
            throw Abort(.badRequest, reason: "state must be success|failure")
        }
        let updated: JobStore.Job
        do {
            updated = try await jobs.report(
                id: id, runnerID: runner.id,
                state: state, output: body.output, exitCode: body.exitCode
            )
        } catch let e as JobStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        await events.fire(user: updated.repoUser, repo: updated.repoName, event: "workflow_run", payload: [
            "action": state.rawValue,
            "jobID": updated.id,
            "workflow": updated.workflow,
            "ref": updated.ref,
            "state": updated.state.rawValue,
            "runnerID": runner.id,
            "runnerName": runner.name,
            "exitCode": updated.exitCode ?? -1,
        ])
        let resp = Response(status: .ok)
        try resp.content.encode(JobDTO.from(updated), as: .json)
        return resp
    }
}

// MARK: - DTOs

private struct RegisterRunnerDTO: Content {
    let name: String
    let labels: [String]?
}

private struct RegisteredRunnerDTO: Content {
    let id: Int
    let name: String
    let token: String
    let labels: [String]
    let createdAt: Date
}

private struct RunnerDTO: Content {
    let id: Int
    let name: String
    let labels: [String]
    let registeredBy: String
    let createdAt: Date
    let lastSeenAt: Date?

    static func from(_ r: RunnerStore.Runner) -> RunnerDTO {
        RunnerDTO(
            id: r.id, name: r.name, labels: r.labels,
            registeredBy: r.registeredBy,
            createdAt: r.createdAt, lastSeenAt: r.lastSeenAt
        )
    }
}

private struct RunnerListDTO: Content {
    let count: Int
    let runners: [RunnerDTO]
}

private struct EnqueueJobDTO: Content {
    let workflow: String
    let ref: String
    let payload: String?
    let labels: [String]?
}

private struct JobStatusDTO: Content {
    let state: String
    let output: String?
    let exitCode: Int?
}

private struct JobDTO: Content {
    let id: Int
    let repoUser: String
    let repoName: String
    let workflow: String
    let ref: String
    let payload: String?
    let labels: [String]
    let state: String
    let runnerID: Int?
    let requestedBy: String
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let exitCode: Int?
    let output: String?

    static func from(_ j: JobStore.Job) -> JobDTO {
        JobDTO(
            id: j.id, repoUser: j.repoUser, repoName: j.repoName,
            workflow: j.workflow, ref: j.ref, payload: j.payload,
            labels: j.labels, state: j.state.rawValue,
            runnerID: j.runnerID, requestedBy: j.requestedBy,
            createdAt: j.createdAt, startedAt: j.startedAt,
            finishedAt: j.finishedAt, exitCode: j.exitCode, output: j.output
        )
    }
}

private struct JobListDTO: Content {
    let user: String
    let repo: String
    let count: Int
    let jobs: [JobDTO]
}
