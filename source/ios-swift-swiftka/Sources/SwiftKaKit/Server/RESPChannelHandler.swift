import Foundation
import NIOCore

/// SwiftNIO inbound handler that:
///   1. accumulates incoming bytes in a ``RESPParser``,
///   2. decodes each fully-arrived RESP value into a ``RESPCommand``,
///   3. asks the ``CommandDispatcher`` for a reply,
///   4. writes the encoded reply back through the channel,
///   5. closes the channel on `QUIT`.
public final class RESPChannelHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let dispatcher: CommandDispatcher
    private let state = CommandDispatcher.ConnectionState()
    private let parser = RESPParser()

    public init(dispatcher: CommandDispatcher) {
        self.dispatcher = dispatcher
    }

    public func channelActive(context: ChannelHandlerContext) {
        // Bind the per-connection state to its NIO channel so SUBSCRIBE
        // / PSUBSCRIBE can register with the pub/sub broker, and (Phase 24)
        // register with the ClientRegistry so CLIENT INFO/LIST surface
        // this connection.
        state.channel = context.channel
        _ = dispatcher.clients?.register(channel: context.channel)
        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        // Drop any pub/sub registrations the connection held.
        if let broker = dispatcher.pubsub, let ch = state.channel {
            broker.removeChannel(ch)
        }
        // Drop the client registry entry too.
        if let registry = dispatcher.clients, let ch = state.channel {
            registry.unregister(channel: ch)
        }
        state.channel = nil
        context.fireChannelInactive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        parser.feed(bytes)
        do {
            while true {
                guard let value = try parser.next() else { break }
                guard let cmd = RESPCommand.decode(value) else {
                    let reply = RESPValue.error("ERR malformed command frame")
                    writeReply(reply, context: context, close: false)
                    continue
                }
                let reply = dispatcher.dispatch(cmd, state: state)
                // Phase 24 — keep the client registry's last-command
                // fields in sync so CLIENT INFO/LIST report sensibly.
                if let registry = dispatcher.clients,
                   let info = registry.info(for: context.channel) {
                    info.lastCommandMs = ClientRegistry.nowMS()
                    info.lastCommand = cmd.name.lowercased()
                    info.protoVersion = state.protocolVersion
                    if !state.name.isEmpty { info.name = state.name }
                }
                let close = cmd.name == "QUIT"
                writeReply(reply, context: context, close: close)
            }
        } catch {
            let reply = RESPValue.error("ERR protocol error: \(error)")
            writeReply(reply, context: context, close: true)
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func writeReply(_ value: RESPValue,
                            context: ChannelHandlerContext,
                            close: Bool) {
        let data = RESPSerializer.encode(value)
        var buf = context.channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        if close {
            // Vapor-memory rule: don't chain .flatMap between writes —
            // future completes when flushed, not when written. Use
            // writeAndFlush + .close on completion.
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(self.wrapOutboundOut(buf), promise: promise)
            promise.futureResult.whenComplete { _ in
                context.close(promise: nil)
            }
        } else {
            context.writeAndFlush(self.wrapOutboundOut(buf), promise: nil)
        }
    }
}
