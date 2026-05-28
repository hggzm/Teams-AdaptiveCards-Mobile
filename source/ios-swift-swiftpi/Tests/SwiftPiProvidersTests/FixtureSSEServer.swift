// FixtureSSEServer — minimal NIO HTTP server used by
// `AnthropicProviderTests` to simulate the Anthropic Messages
// streaming endpoint without hitting the network.
//
// Usage:
//
//     let fixture = try await FixtureSSEServer.start(
//         tape: someSSEPayload,
//         status: .ok
//     )
//     defer { try? await fixture.shutdown() }
//     // fixture.baseURL → http://127.0.0.1:<port>
//
// The server accepts a single POST request, replies with the
// supplied status and SSE body, then idles. It is intentionally
// stupid; it does NOT validate headers or paths.

import Foundation
import NIO
import NIOHTTP1
import NIOPosix

public actor FixtureSSEServer {
    public struct Recording: Sendable {
        public var status: HTTPResponseStatus
        public var body: String
        public var contentType: String

        public init(
            status: HTTPResponseStatus = .ok,
            body: String,
            contentType: String = "text/event-stream"
        ) {
            self.status = status
            self.body = body
            self.contentType = contentType
        }
    }

    public let baseURL: String
    public let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, port: Int) {
        self.group = group
        self.channel = channel
        self.port = port
        self.baseURL = "http://127.0.0.1:\(port)"
    }

    /// Start a fresh server bound to 127.0.0.1 on an OS-chosen port.
    public static func start(_ recording: Recording) async throws -> FixtureSSEServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            // SO_REUSEADDR would be useful but pulling in the platform's
            // socket constants (SOL_SOCKET / SO_REUSEADDR) requires
            // Darwin/Glibc/WinSDK imports — and we bind to port 0 (OS-
            // chosen ephemeral) anyway, so the rebind-window concern
            // doesn't apply.
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
                    .flatMap {
                        channel.pipeline.addHandler(
                            FixtureHandler(recording: recording)
                        )
                    }
            }
        do {
            let serverChannel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            guard let port = serverChannel.localAddress?.port else {
                try await serverChannel.close()
                try await group.shutdownGracefully()
                throw FixtureError.noLocalPort
            }
            return FixtureSSEServer(group: group, channel: serverChannel, port: port)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func shutdown() async throws {
        try await channel.close()
        try await group.shutdownGracefully()
    }
}

public enum FixtureError: Error {
    case noLocalPort
}

// MARK: - Internal handler

private final class FixtureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let recording: FixtureSSEServer.Recording

    init(recording: FixtureSSEServer.Recording) {
        self.recording = recording
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head:
            // Wait for end before replying so async-http-client's
            // request fully completes its write.
            break
        case .body:
            break
        case .end:
            sendResponse(context: context)
        }
    }

    private func sendResponse(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: recording.contentType)
        headers.add(name: "content-length", value: "\(recording.body.utf8.count)")
        headers.add(name: "connection", value: "close")
        let head = HTTPResponseHead(
            version: .init(major: 1, minor: 1),
            status: recording.status,
            headers: headers
        )
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: recording.body.utf8.count)
        buffer.writeString(recording.body)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        // NIO serializes operations on the event loop, so emitting the
        // end-of-response followed by a close(promise: nil) is safe —
        // the close runs after the flush, in order. Doing it this way
        // avoids a non-Sendable `context` capture inside a @Sendable
        // whenComplete closure (a 6.x sendability tightening).
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
}
