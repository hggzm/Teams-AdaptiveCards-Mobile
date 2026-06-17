// Sources/GiteaxServer/main.swift
//
// Thin executable wrapper around the `Giteax` library. Reads bind
// address + repo root from env vars and hands the application off to
// `configureGiteax(_:root:)`. Embedding apps that already own a Vapor
// `Application` should depend on the `Giteax` library product directly
// instead of shelling out to this binary.
//
//   GITEAX_HOST   bind host (default 127.0.0.1)
//   GITEAX_PORT   bind port (default 5080)
//   GITEAX_ROOT   on-disk repo root (default ./repos)
//
// All other env vars (GITEAX_ADMIN_TOKEN, GITEAX_ALLOW_PUSH,
// GITEAX_ALLOW_ANON_PUSH, GITEAX_SSH_PORT, GITEAX_SSH_HOST) are
// consumed inside `configureGiteax` itself.

import Foundation
import Vapor
import Giteax

@main
struct Entry {
    static func main() async throws {
        let env = try Environment.detect()
        let app = try await Application.make(env)

        let rootPath = Environment.process.GITEAX_ROOT ?? "./repos"
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

        let host = Environment.process.GITEAX_HOST ?? "127.0.0.1"
        let portString = Environment.process.GITEAX_PORT ?? "5080"
        guard let port = Int(portString) else {
            app.logger.error("GITEAX_PORT='\(portString)' is not an integer")
            try await app.asyncShutdown()
            return
        }

        do {
            try await configureGiteax(app, root: rootURL)
        } catch {
            app.logger.report(error: error)
            try await app.asyncShutdown()
            return
        }

        app.http.server.configuration.hostname = host
        app.http.server.configuration.port = port

        do {
            try await app.execute()
        } catch {
            app.logger.report(error: error)
        }
        try await app.asyncShutdown()
    }
}
