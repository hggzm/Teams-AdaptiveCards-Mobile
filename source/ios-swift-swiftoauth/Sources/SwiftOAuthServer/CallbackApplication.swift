// SwiftOAuthServer — Hummingbird application wrapper for the loopback server.
//
// We conform to `ApplicationProtocol` and call `run()` (NOT `runService()`):
// `runService()` installs SIGTERM/SIGINT graceful-shutdown handlers that do not
// exist on Windows. Shutting down is instead driven by Task cancellation from
// `CallbackServer.run`. `onServerRunning` reports the actually-bound port so an
// ephemeral `port: 0` request can be turned into a concrete redirect URI.
import Foundation
import Hummingbird
import NIOCore

struct CallbackApplication: ApplicationProtocol {
    typealias Context = BasicRequestContext

    // Store the already-built responder (which is `Sendable`), not the
    // `Router` (which is not), so the application struct stays `Sendable`.
    let appResponder: RouterResponder<Context>
    let host: String
    let port: Int
    let onBound: @Sendable (Int) async -> Void

    var configuration: ApplicationConfiguration {
        .init(
            address: .hostname(host, port: port),
            serverName: "swiftoauth-callback"
        )
    }

    var responder: some HTTPResponder<Context> {
        appResponder
    }

    func onServerRunning(_ channel: any Channel) async {
        // `port: 0` binds an ephemeral port; read the real one back off the
        // bound channel so the caller can form the exact redirect URI.
        let bound = channel.localAddress?.port ?? port
        await onBound(bound)
    }
}
