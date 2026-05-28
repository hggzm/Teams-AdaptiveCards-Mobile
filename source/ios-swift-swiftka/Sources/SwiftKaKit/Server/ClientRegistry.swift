import Foundation
import NIOCore

/// Process-wide registry of active client connections. Powers
/// `CLIENT INFO` / `CLIENT LIST` / `CLIENT KILL` / `CLIENT NO-EVICT`.
///
/// Connections register themselves on `channelActive` (via
/// ``RESPChannelHandler``) and unregister on `channelInactive`. The
/// registry is NSLock-guarded so it remains usable from synchronous
/// ChannelInboundHandler code.
public final class ClientRegistry: @unchecked Sendable {
    public final class ClientInfo: @unchecked Sendable {
        public let id: Int64
        public let channel: Channel
        public let addr: String
        public let connectMs: Int64
        public var name: String = ""
        public var lastCommandMs: Int64
        public var lastCommand: String = ""
        public var protoVersion: Int = 2
        public var library: String = ""
        public var libraryVersion: String = ""

        init(id: Int64, channel: Channel, addr: String, connectMs: Int64) {
            self.id = id
            self.channel = channel
            self.addr = addr
            self.connectMs = connectMs
            self.lastCommandMs = connectMs
        }
    }

    private let lock = NSLock()
    private var nextId: Int64 = 1
    private var clients: [ObjectIdentifier: ClientInfo] = [:]

    public init() {}

    /// Registers a freshly-opened connection and returns the
    /// auto-assigned client id.
    @discardableResult
    public func register(channel: Channel) -> ClientInfo {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        let addr = (channel.remoteAddress?.description) ?? "?"
        let info = ClientInfo(
            id: id,
            channel: channel,
            addr: addr,
            connectMs: Self.nowMS()
        )
        clients[ObjectIdentifier(channel)] = info
        return info
    }

    public func unregister(channel: Channel) {
        lock.lock(); defer { lock.unlock() }
        clients.removeValue(forKey: ObjectIdentifier(channel))
    }

    public func info(for channel: Channel) -> ClientInfo? {
        lock.lock(); defer { lock.unlock() }
        return clients[ObjectIdentifier(channel)]
    }

    /// Looks up by Redis-style numeric client id.
    public func info(byId id: Int64) -> ClientInfo? {
        lock.lock(); defer { lock.unlock() }
        return clients.values.first(where: { $0.id == id })
    }

    /// Snapshot of every active client (used by CLIENT LIST).
    public func snapshot() -> [ClientInfo] {
        lock.lock(); defer { lock.unlock() }
        return Array(clients.values).sorted { $0.id < $1.id }
    }

    /// Kills the connection associated with `id`. Returns true if a
    /// matching client was found.
    @discardableResult
    public func kill(id: Int64) -> Bool {
        let target: ClientInfo?
        lock.lock()
        target = clients.values.first(where: { $0.id == id })
        lock.unlock()
        guard let info = target else { return false }
        // Close on the channel's event loop. The handler's
        // channelInactive will unregister.
        info.channel.close(promise: nil)
        return true
    }

    /// Returns the per-client status line that CLIENT LIST emits.
    /// One line per client, fields separated by spaces, matching
    /// Redis's exact wire format closely enough for tooling.
    public func formattedLine(_ c: ClientInfo) -> String {
        let now = Self.nowMS()
        let idle = max(0, (now - c.lastCommandMs) / 1000)
        let age = max(0, (now - c.connectMs) / 1000)
        return "id=\(c.id) addr=\(c.addr) name=\(c.name) age=\(age) idle=\(idle) cmd=\(c.lastCommand) proto=\(c.protoVersion) lib-name=\(c.library) lib-ver=\(c.libraryVersion)"
    }

    public static func nowMS() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
