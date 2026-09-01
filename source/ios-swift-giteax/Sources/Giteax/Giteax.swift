import Vapor
import SwiftGitX
import Foundation

/// Wire all Giteax features (REST API, smart-HTTP, optional SSH listener,
/// webhooks, stores, hooks, HTML UI, code search, etc.) onto an existing
/// Vapor `Application`. The caller owns the application lifecycle: set
/// `app.http.server.configuration` and run `try await app.execute()` /
/// `app.asyncShutdown()` yourself.
///
/// Optional features remain env-var driven so embedding apps opt in by
/// setting them before calling:
///   - `GITEAX_ADMIN_TOKEN`     (admin API bearer; unset = admin disabled)
///   - `GITEAX_ALLOW_PUSH=1`    (enables git-receive-pack + auth)
///   - `GITEAX_ALLOW_ANON_PUSH=1` (only meaningful when user store empty)
///   - `GITEAX_SSH_PORT=<int>`  (enables NIOSSH listener)
///   - `GITEAX_SSH_HOST=<host>` (defaults to 0.0.0.0 when port set)
///
/// - Parameter app: Caller-owned Vapor application.
/// - Parameter rootURL: Filesystem directory that holds bare repos under
///   `<root>/<user>/<repo>.git` plus `.giteax/` state.
public func configureGiteax(_ app: Application, root rootURL: URL) async throws {
    // ── Phase 3 wiring: RepositoryService on top of root URL ──────────
    let service = RepositoryService(root: rootURL)
    app.logger.notice("[giteax] repo root: \(rootURL.path)")

        // GET / -> minimal hello landing. Phase 2 acceptance.
        app.get { _ async -> String in
            "hello, gitea"
        }

        // GET /health -> standard liveness probe.
        app.get("health") { _ async -> String in
            "ok"
        }

        // GET /version -> versions of the runtime + git engine. Useful
        // when a user files a bug; also confirms SwiftGitX linked properly.
        app.get("version") { _ async -> String in
            let swiftVer: String
            #if swift(>=6.0)
            swiftVer = "Swift 6.x"
            #else
            swiftVer = "Swift <6"
            #endif
            return """
            giteax/0.0.21 (\(swiftVer))
            SwiftGitX/0.4.0+hggz.windows-msvc-enum-bridging+merge-bridging
            libgit2/1.9.2+hggz.windows-schannel
            """
        }

        // ── Phase 8 wiring: user store + admin token + push auth ─────────
        let userStore: UserStore
        do {
            userStore = try UserStore(root: rootURL)
            let count = await userStore.count()
            app.logger.notice("[giteax] user store: \(count) user(s) at \(rootURL.appendingPathComponent(".giteax/users.json").path)")
        } catch {
            app.logger.error("[giteax] user store failed to load: \(error). Aborting.")
            throw error
        }
        let adminToken: String? = {
            let v = Environment.process.GITEAX_ADMIN_TOKEN ?? ""
            return v.isEmpty ? nil : v
        }()
        if adminToken == nil {
            app.logger.warning("[giteax] GITEAX_ADMIN_TOKEN unset; admin API disabled (POST/DELETE /api/users return 503)")
        }
        registerUserRoutes(app, store: userStore, adminToken: adminToken)

        // ── Phase 15a SSH public-key store + management API ─────────────────────
        // The SSH server listener itself ships in Phase 15b. This commit
        // gives users a place to register their keys; the listener will
        // pick them up at connection time once 15b ships.
        let sshKeyStore: SSHKeyStore
        do {
            sshKeyStore = try SSHKeyStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] SSH key store failed to init: \(error). Aborting.")
            throw error
        }
        registerSSHKeyRoutes(app, keyStore: sshKeyStore, userStore: userStore, adminToken: adminToken)
        app.logger.notice("[giteax] SSH key management enabled at /api/users/:name/ssh-keys (Ed25519/RSA/ECDSA accepted; listener pending Phase 15b)")

        // ── Phase 19 wiring: Personal Access Tokens ────────────────────────
        // PATs are per-user, revocable bearer credentials. They work
        // wherever HTTP Basic auth works (password slot, prefix
        // `giteax_pat_`) and as `Authorization: Bearer …`. Stored
        // hashed (SHA-256); plaintext is shown once at creation.
        let tokenStore: TokenStore
        do {
            tokenStore = try TokenStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] token store failed to init: \(error). Aborting.")
            throw error
        }
        registerTokenRoutes(app, tokenStore: tokenStore, userStore: userStore, adminToken: adminToken)
        app.logger.notice("[giteax] PATs enabled at /api/users/:name/tokens (self or admin to manage)")
        // ── Phase 7 wiring: SmartHTTPService (clone/push via git-http-backend) ─
        // SmartHTTPService throws at construction if it can't find the CGI
        // helper. That's a soft failure -- log it and continue without the
        // smart-HTTP routes registered.
        let allowPush = (Environment.process.GITEAX_ALLOW_PUSH ?? "0") == "1"
        let allowAnonPush = (Environment.process.GITEAX_ALLOW_ANON_PUSH ?? "0") == "1"
        let smart: SmartHTTPService?
        do {
            smart = try SmartHTTPService(root: rootURL, allowPush: allowPush)
            app.logger.notice(
                "[giteax] smart-HTTP enabled (push: \(allowPush ? "ALLOWED" : "disabled"))"
            )
        } catch {
            smart = nil
            app.logger.warning(
                "[giteax] smart-HTTP disabled: \(error). Set git on PATH to enable git clone/push."
            )
        }

        // Push auth: only wire up when push is allowed at the env-flag level.
        // When users exist, HTTP Basic is required. When the user store is
        // empty, GITEAX_ALLOW_ANON_PUSH=1 falls back to Phase-7 open behavior.
        let pushAuth: GitPushBasicAuth?
        if allowPush {
            pushAuth = GitPushBasicAuth(store: userStore, tokens: tokenStore, allowAnonPush: allowAnonPush)
            let storeEmpty = await userStore.isEmpty()
            if storeEmpty {
                if allowAnonPush {
                    app.logger.warning("[giteax] no users yet AND GITEAX_ALLOW_ANON_PUSH=1 -> push is OPEN to anyone")
                } else {
                    app.logger.warning("[giteax] no users yet; pushes will be refused until a user is created (POST /api/users)")
                }
            }
        } else {
            pushAuth = nil
        }

        // ── Phase 9 wiring: issue store (route registration deferred) ─────
        let issueStore: IssueStore
        do {
            issueStore = try IssueStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] issue store failed to init: \(error). Aborting.")
            throw error
        }

        // ── Phase 10 wiring: pull-request store (FF-merge only) ─────────
        let prStore: PullRequestStore
        do {
            prStore = try PullRequestStore(root: rootURL, repoService: service)
        } catch {
            app.logger.error("[giteax] PR store failed to init: \(error). Aborting.")
            throw error
        }

        // ── Phase 36 wiring: PR review approvals store ──────────────
        let reviewStore: PRReviewStore
        do {
            reviewStore = try PRReviewStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] review store failed to init: \(error). Aborting.")
            throw error
        }

        // ── Phase 11 wiring: webhook store + dispatcher ────────────────
        // Must construct the dispatcher BEFORE any route registration so
        // that route handlers can fan events back through it.
        let webhookStore: WebhookStore
        do {
            webhookStore = try WebhookStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] webhook store failed to init: \(error). Aborting.")
            throw error
        }
        let dispatcher = WebhookDispatcher(store: webhookStore, app: app)

        // ── Phase 12 wiring: per-repo metadata + access controller ─────────
        let metaStore: RepoMetaStore
        do {
            metaStore = try RepoMetaStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] repo-meta store failed to init: \(error). Aborting.")
            throw error
        }
        // ── Phase 40 wiring: organizations + teams (consulted by AC) ───────
        let orgStore: OrgStore
        do {
            orgStore = try OrgStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] org store failed to init: \(error). Aborting.")
            throw error
        }

        var accessCtl = AccessController(meta: metaStore, users: userStore)
        accessCtl.orgs = orgStore
        registerRepoMetaRoutes(app, meta: metaStore, access: accessCtl)
        app.logger.notice("[giteax] per-repo ACL enabled at /api/repos/:user/:repo/settings and /collaborators")
        registerOrgRoutes(app, orgs: orgStore, users: userStore, pushAuth: pushAuth, adminToken: adminToken)
        app.logger.notice("[giteax] orgs+teams API enabled at /api/orgs (admin-gated create/delete)")

        // ── Phase 41 wiring: forks + lineage (consulted by cross-fork PRs) ─
        let forkStore: ForkStore
        do {
            forkStore = try ForkStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] fork store failed to init: \(error). Aborting.")
            throw error
        }
        registerForkRoutes(app, forks: forkStore, orgs: orgStore, pushAuth: pushAuth, access: accessCtl, rootURL: rootURL)
        app.logger.notice("[giteax] fork API enabled at /api/repos/:u/:r/forks (auth-gated POST; lineage tracked in .giteax/forks.json)")

        // ── Phase 42 wiring: labels + milestones ────────────────────────
        let labelStore: LabelStore
        let milestoneStore: MilestoneStore
        do {
            labelStore     = try LabelStore(root: rootURL)
            milestoneStore = try MilestoneStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] label/milestone store failed to init: \(error). Aborting.")
            throw error
        }
        registerLabelRoutes(app, labels: labelStore, milestones: milestoneStore, pushAuth: pushAuth, access: accessCtl)
        app.logger.notice("[giteax] labels + milestones API enabled at /api/repos/:u/:r/{labels,milestones}")

        // ── Phase 43 wiring: stars + watches + activity feed ───────────
        let starStore: StarStore
        let watchStore: WatchStore
        let activityStore: ActivityStore
        do {
            starStore     = try StarStore(root: rootURL)
            watchStore    = try WatchStore(root: rootURL)
            activityStore = try ActivityStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] star/watch/activity store failed to init: \(error). Aborting.")
            throw error
        }
        registerStarWatchRoutes(
            app,
            stars: starStore, watches: watchStore, activity: activityStore,
            users: userStore, pushAuth: pushAuth, access: accessCtl, rootURL: rootURL)
        app.logger.notice("[giteax] stars + watches + activity feed enabled at /api/repos/:u/:r/{star,watch,stargazers,watchers,activity} and /api/users/:name/{starred,watched,feed}")

        // ── Phase 44 wiring deferred until after releaseStore + codeIndex.

        // Composite EventSink: fan all `events: ...` route fire-calls
        // to BOTH the webhook dispatcher AND the per-repo activity log.
        let activitySink = ActivityEventSink(store: activityStore)
        let eventSink: any EventSink = CompositeEventSink([dispatcher, activitySink])

        // ── Phase 27/28 hook installer + internal callback endpoints ────────
        // Read GITEAX_PORT/HOST early so the installer can bake the
        // loopback URL into the on-disk hook scripts. The server binds
        // later (below), but the installer only renders scripts -- the
        // scripts execute at push time, by which point the server is up.
        let earlyHost = Environment.process.GITEAX_HOST ?? "127.0.0.1"
        let earlyPort = Environment.process.GITEAX_PORT ?? "5080"
        let internalURL = "http://127.0.0.1:\(earlyPort)"   // hooks always loopback
        _ = earlyHost   // captured for logging consistency
        let hookInstaller = HookInstaller(
            rootURL: rootURL,
            metaStore: metaStore,
            serverURL: internalURL,
            logger: app.logger
        )
        registerInternalHookRoutes(app, metaStore: metaStore, events: eventSink, access: accessCtl)
        app.logger.notice("[giteax] internal hook endpoints at /api/internal/hook/:user/:repo/{pre,post}-receive (loopback-only; per-repo token)")

        // ── Phase 3-8 repo routes ──────────────────────────────────────────────────
        registerRepoRoutes(app, service: service, smart: smart, pushAuth: pushAuth, events: eventSink, access: accessCtl, hookInstaller: hookInstaller, metaStore: metaStore)

        // ── Phase 9-10 social-layer routes ────────────────────────────────
        registerIssueRoutes(app, store: issueStore, pushAuth: pushAuth, events: eventSink, access: accessCtl, milestones: milestoneStore, users: userStore)
        app.logger.notice("[giteax] issue tracker enabled at /api/repos/:user/:repo/issues")
        registerPullRequestRoutes(app, store: prStore, pushAuth: pushAuth, events: eventSink, access: accessCtl, metaStore: metaStore, reviewStore: reviewStore, forks: forkStore, rootURL: rootURL, users: userStore)
        app.logger.notice("[giteax] PR tracker enabled at /api/repos/:user/:repo/pulls (FF-merge only; cross-fork via head=owner:branch)")
        registerPRReviewRoutes(app, store: reviewStore, prStore: prStore, pushAuth: pushAuth, events: eventSink, access: accessCtl)
        app.logger.notice("[giteax] PR reviews enabled at /api/repos/:user/:repo/pulls/:n/reviews (settings.requiredApprovals gates merge)")

        // ── Phase 39 wiring: Actions-style runners + jobs ─────────────────
        let runnerStore: RunnerStore
        let jobStore: JobStore
        do {
            runnerStore = try RunnerStore(root: rootURL)
            jobStore = try JobStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] runner/job stores failed to init: \(error). Aborting.")
            throw error
        }
        registerRunnerRoutes(
            app, runners: runnerStore, jobs: jobStore,
            pushAuth: pushAuth, events: eventSink,
            access: accessCtl, adminToken: adminToken
        )
        app.logger.notice("[giteax] actions runners enabled at /api/admin/runners + /api/repos/:u/:r/actions/jobs + /api/runners/jobs (workflow_run webhook event)")

        // ── Phase 11 webhook routes ────────────────────────────────────────
        registerWebhookRoutes(app, store: webhookStore, dispatcher: dispatcher, pushAuth: pushAuth, access: accessCtl)
        app.logger.notice("[giteax] webhooks enabled at /api/repos/:user/:repo/hooks (events: push, pull_request, pull_request_review, issue, issue_comment, pull_request_comment, workflow_run, ping)")
        // ── Phase 13 release routes ───────────────────────────────────────
        let releaseStore: ReleaseStore
        do {
            releaseStore = try ReleaseStore(root: rootURL, repoService: service)
        } catch {
            app.logger.error("[giteax] release store failed to init: \(error). Aborting.")
            throw error
        }
        registerReleaseRoutes(app, store: releaseStore, access: accessCtl, pushAuth: pushAuth)
        app.logger.notice("[giteax] releases enabled at /api/repos/:user/:repo/releases (tag-backed; admin to create/edit; assets up to 256 MiB)")

        // ── Phase 17 LFS routes ───────────────────────────────────────────
        registerLFSRoutes(app, rootURL: rootURL, pushAuth: pushAuth, access: accessCtl)
        app.logger.notice("[giteax] LFS enabled at /:user/:repo.git/info/lfs/* (basic transfer; 4 GiB per object)")
        // ── Phase 22 Wiki routes ──────────────────────────────────────────
        let wikiStore = WikiStore(root: rootURL)
        registerWikiRoutes(app, store: wikiStore, pushAuth: pushAuth, access: accessCtl)
        app.logger.notice("[giteax] wiki enabled at /api/repos/:user/:repo/wiki/pages (markdown; write= permission)")

        // ── Phase 25 code-search routes ─────────────────────────────────────
        // Phase 29: wrap an FTS5 index around the same surface; the in-memory
        // walker remains the fallback for unborn-HEAD repos and ?ref= queries.
        let codeIndex = CodeIndex(rootURL: rootURL, service: service)
        registerCodeSearchRoutes(app, service: service, access: accessCtl, codeIndex: codeIndex)
        app.logger.notice("[giteax] code search enabled at /api/repos/:user/:repo/search/code (FTS5-indexed; ?ref= forces in-memory walker; ?q=, ?limit=, ?max_files=)")

        // ── Phase 44 wiring: repo transfer + rename ────────────────────
        registerTransferRoutes(
            app,
            forks: forkStore, stars: starStore, watches: watchStore,
            meta: metaStore, issues: issueStore, labels: labelStore,
            milestones: milestoneStore, prs: prStore, webhooks: webhookStore,
            releases: releaseStore, reviews: reviewStore, codeIndex: codeIndex,
            orgs: orgStore, pushAuth: pushAuth, access: accessCtl,
            rootURL: rootURL)
        app.logger.notice("[giteax] repo transfer + rename enabled at POST /api/repos/:u/:r/{transfer,rename}")

        // ── Phase 45 wiring: user + org avatars ─────────────────────────
        registerAvatarRoutes(
            app,
            users: userStore, orgs: orgStore, pushAuth: pushAuth,
            access: accessCtl, rootURL: rootURL)
        app.logger.notice("[giteax] avatars enabled at /api/{users|orgs}/:name/avatar (PNG/JPEG/GIF/WebP, max 1 MiB)")

        // ── Phase 46 wiring: TOTP 2FA enrollment ───────────────────────
        let totpStore: TotpStore
        do {
            totpStore = try TotpStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] totp store failed to init: \(error). Aborting.")
            throw error
        }
        registerTotpRoutes(
            app,
            totp: totpStore, users: userStore,
            pushAuth: pushAuth, access: accessCtl, adminToken: adminToken)
        app.logger.notice("[giteax] TOTP 2FA enrollment enabled at /api/users/:name/2fa/{setup,activate,verify,status,recovery/use} (SHA1, 30s, 6 digits)")

        // ── Phase 47 wiring: issue + PR templates ──────────────────────
        let templateStore = TemplateStore(root: rootURL)
        registerTemplateRoutes(app, templates: templateStore, pushAuth: pushAuth, access: accessCtl)
        app.logger.notice("[giteax] issue/PR templates enabled at /api/repos/:u/:r/templates[/{issue|pull}[/:name]] (max 32 per kind, 64 KiB per body)")

        // ── Phase 48 wiring: cron + background ticker ──────────────────
        let cronStore: CronStore
        do {
            cronStore = try CronStore(root: rootURL)
        } catch {
            app.logger.error("[giteax] cron store failed to init: \(error). Aborting.")
            throw error
        }
        registerCronRoutes(app, store: cronStore, adminToken: adminToken, logger: app.logger)
        let cronTicker = CronTicker(store: cronStore, logger: app.logger)
        await cronTicker.start()
        app.logger.notice("[giteax] cron enabled at /api/cron (admin-only; 1 s tick; interval range [\(CronStore.minIntervalSeconds), \(CronStore.maxIntervalSeconds)] s)")

        // ── Phase 49 wiring: per-repo upstream mirroring ──────────────
        let mirrorStore = MirrorStore(root: rootURL)
        let mirrorTicker = MirrorTicker(store: mirrorStore, root: rootURL, logger: app.logger)
        registerMirrorRoutes(app, mirrors: mirrorStore, ticker: mirrorTicker, repos: service, pushAuth: pushAuth, access: accessCtl, logger: app.logger)
        await mirrorTicker.start()
        app.logger.notice("[giteax] mirror enabled at /api/repos/:u/:r/mirror (10 s tick; interval range [\(MirrorStore.minIntervalSeconds), \(MirrorStore.maxIntervalSeconds)] s)")

        // ── Phase 26 package registry routes ────────────────────────────────────
        let packageStore = PackageStore(root: rootURL)
        registerPackageRoutes(app, store: packageStore, pushAuth: pushAuth, access: accessCtl)
        app.logger.notice("[giteax] package registry enabled at /api/repos/:user/:repo/packages/:type/:name/:version (256 MiB per file)")
        // ── Phase 18 search routes ────────────────────────────────────────
        registerSearchRoutes(
            app,
            rootURL: rootURL,
            metaStore: metaStore,
            issueStore: issueStore,
            prStore: prStore,
            access: accessCtl
        )
        app.logger.notice("[giteax] search enabled at /api/search/issues and /api/search/pulls")

        // ── Phase 14 HTML UI routes ───────────────────────────────────────
        registerHTMLRoutes(
            app,
            service: service,
            metaStore: metaStore,
            issueStore: issueStore,
            prStore: prStore,
            releaseStore: releaseStore,
            rootURL: rootURL,
            access: accessCtl
        )
        app.logger.notice("[giteax] HTML UI enabled at /ui (read-only browse)")

        // SSH listener disabled in this vendored snapshot to avoid the
        // NIOSSH dependency. The REST endpoints for managing per-user SSH
        // key strings remain (see registerSSHKeyRoutes); the on-the-wire
        // listener is not part of this drop.
        app.logger.info("[giteax-ssh] not built in this snapshot (SSH listener target dropped)")
}
