import Foundation
import NIOCore
import NIOPosix

/// Embedded swiftka TCP server. Listens for RESP2 clients on a host:port
/// pair and dispatches commands through ``CommandDispatcher``.
///
/// `@unchecked Sendable` because `channel` is only mutated from `start`
/// (which is the single boot path) and read from `shutdown` /
/// `waitUntilClosed` after a `start` has completed. SwiftPM's strict
/// concurrency mode is happy and the contract is "one boot per server
/// instance".
public final class SwiftKaServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int

        public init(host: String = "127.0.0.1", port: Int = 6479) {
            self.host = host
            self.port = port
        }
    }

    public let configuration: Configuration
    public let dispatcher: CommandDispatcher

    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(configuration: Configuration = .init(),
                dispatcher: CommandDispatcher = .init()) {
        self.configuration = configuration
        self.dispatcher = dispatcher
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Convenience initialiser that wires up an in-memory swiftka
    /// instance — handy for tests / examples that need an end-to-end
    /// server without a file backing.
    public convenience init(host: String = "127.0.0.1", port: Int = 0) throws {
        let db = try Database(path: ":memory:")
        let keys = KeyStore(database: db)
        let broker = PubSubBroker()
        let clients = ClientRegistry()
        let dispatcher = CommandDispatcher(keys: keys, pubsub: broker, clients: clients)
        self.init(configuration: .init(host: host, port: port),
                  dispatcher: dispatcher)
    }

    /// Binds the listener and returns the actually-bound port (useful
    /// when the caller asked for port 0).
    public func start() async throws -> Int {
        let dispatcher = self.dispatcher
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(RESPChannelHandler(dispatcher: dispatcher))
            }
        // SO_REUSEADDR / TCP_NODELAY would go here but
        // `ChannelOptions.socket(_:_:)` is not available on Windows in
        // hggz/swift-nio:windows-joannis-mirror (per /memories/repo/
        // vapor-windows.md). Skip those tuning knobs on every platform
        // for now to keep the bootstrap portable.
        let bound = try await bootstrap.bind(host: configuration.host,
                                             port: configuration.port).get()
        self.channel = bound
        let actual = bound.localAddress?.port ?? configuration.port
        return actual
    }

    /// Returns once the listener channel is closed.
    public func waitUntilClosed() async throws {
        if let ch = channel {
            try await ch.closeFuture.get()
        }
    }

    /// Stops the listener and shuts down the event loop group.
    public func shutdown() async throws {
        if let ch = channel {
            try await ch.close()
        }
        try await group.shutdownGracefully()
    }
}
