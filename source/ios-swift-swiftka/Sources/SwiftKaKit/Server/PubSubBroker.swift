import Foundation
import NIOCore

/// Process-wide pub/sub broker. Subscribers register themselves
/// (`addChannel(_:on:)`) and unregister; publishers (`publish(_:to:)`)
/// fan a payload out to every registered channel on the given channel
/// names. Implementation uses an `NSLock` rather than an actor so it
/// stays usable from synchronous ChannelInboundHandler code.
public final class PubSubBroker: @unchecked Sendable {
    /// One registration per (subscriber, channel-name) pair. We hold a
    /// non-owning reference to the SwiftNIO Channel for delivery; the
    /// subscriber removes itself via `removeChannel` on connection
    /// close.
    ///
    /// `protocolVersion` is captured at SUBSCRIBE / PSUBSCRIBE time so
    /// the broker can pick the right wire shape on delivery:
    ///   - RESP2 (proto 2): legacy `*3 message <channel> <payload>`
    ///   - RESP3 (proto 3): push frame `>3 message <channel> <payload>`
    public final class Subscriber: Hashable, @unchecked Sendable {
        public let id: ObjectIdentifier
        public let channel: Channel
        public let protocolVersion: Int
        public init(channel: Channel, protocolVersion: Int = 2) {
            self.channel = channel
            self.id = ObjectIdentifier(channel)
            self.protocolVersion = protocolVersion
        }
        public static func == (lhs: Subscriber, rhs: Subscriber) -> Bool {
            lhs.id == rhs.id
        }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    private let lock = NSLock()
    private var subscribers: [String: Set<Subscriber>] = [:]
    /// Reverse index: for each channel, which RESP channel names is it
    /// currently subscribed to. Used so a connection-close handler can
    /// drop every subscription without scanning the full forward map.
    private var owned: [ObjectIdentifier: (Subscriber, Set<String>)] = [:]

    /// Pattern subscriptions. `psubscribers[pattern]` is the set of
    /// channels subscribed to that glob pattern; `ownedPatterns` is
    /// the matching per-channel reverse index used by UNSUBSCRIBE-all
    /// and connection-close cleanup.
    private var psubscribers: [String: Set<Subscriber>] = [:]
    private var ownedPatterns: [ObjectIdentifier: (Subscriber, Set<String>)] = [:]

    /// Sharded pub/sub (Redis 7). In real Redis Cluster, SPUBLISH only
    /// reaches subscribers on the same shard slot as the channel; on
    /// single-node swiftka the routing is trivial, but the keyspace
    /// is still kept fully separate from regular pub/sub so SUBSCRIBE
    /// and SSUBSCRIBE don't cross-deliver.
    private var ssubscribers: [String: Set<Subscriber>] = [:]
    private var ownedShard: [ObjectIdentifier: (Subscriber, Set<String>)] = [:]

    public init() {}

    // MARK: SUBSCRIBE / UNSUBSCRIBE

    /// Subscribes `channel` (NIO Channel) to the RESP channel `name`.
    /// Returns the subscriber's total subscription count post-subscribe.
    /// `protocolVersion` (2 or 3) determines the wire frame shape used
    /// when this subscriber receives a message.
    @discardableResult
    public func subscribe(channel: Channel, to name: String, protocolVersion: Int = 2) -> Int {
        let id = ObjectIdentifier(channel)
        lock.lock(); defer { lock.unlock() }
        let sub: Subscriber
        if let existing = owned[id] {
            sub = existing.0
            owned[id] = (sub, existing.1.union([name]))
        } else {
            sub = Subscriber(channel: channel, protocolVersion: protocolVersion)
            owned[id] = (sub, [name])
        }
        subscribers[name, default: []].insert(sub)
        return owned[id]!.1.count
    }

    /// Unsubscribes from a specific name. If `name == nil`, drops every
    /// subscription this channel held. Returns the remaining count.
    @discardableResult
    public func unsubscribe(channel: Channel, from name: String?) -> [(String, Int)] {
        let id = ObjectIdentifier(channel)
        lock.lock(); defer { lock.unlock() }
        guard let (sub, current) = owned[id] else {
            // Per Redis: UNSUBSCRIBE with no active subs still returns
            // an empty `*3` triple with count=0 — let callers handle
            // that. We just signal "no names" via empty array.
            return []
        }
        var results: [(String, Int)] = []
        let targets: Set<String>
        if let n = name { targets = [n] } else { targets = current }
        var remaining = current
        for n in targets {
            subscribers[n]?.remove(sub)
            if subscribers[n]?.isEmpty == true { subscribers.removeValue(forKey: n) }
            remaining.remove(n)
            results.append((n, remaining.count))
        }
        if remaining.isEmpty {
            owned.removeValue(forKey: id)
        } else {
            owned[id] = (sub, remaining)
        }
        return results
    }

    /// Drops every subscription (channel + pattern + shard) held by
    /// a channel. Used by the connection-close path.
    public func removeChannel(_ channel: Channel) {
        _ = unsubscribe(channel: channel, from: nil)
        _ = punsubscribe(channel: channel, from: nil)
        _ = sunsubscribe(channel: channel, from: nil)
    }

    // MARK: PSUBSCRIBE / PUNSUBSCRIBE

    /// Subscribes `channel` to a glob `pattern`. Returns the channel's
    /// total pattern-subscription count post-subscribe.
    /// `protocolVersion` (2 or 3) is captured for wire-shape selection.
    @discardableResult
    public func psubscribe(channel: Channel, to pattern: String, protocolVersion: Int = 2) -> Int {
        let id = ObjectIdentifier(channel)
        lock.lock(); defer { lock.unlock() }
        let sub: Subscriber
        if let existing = ownedPatterns[id] {
            sub = existing.0
            ownedPatterns[id] = (sub, existing.1.union([pattern]))
        } else {
            sub = Subscriber(channel: channel, protocolVersion: protocolVersion)
            ownedPatterns[id] = (sub, [pattern])
        }
        psubscribers[pattern, default: []].insert(sub)
        return ownedPatterns[id]!.1.count
    }

    /// Unsubscribes from a pattern. `nil` drops every pattern this
    /// channel held. Returns one (pattern, remaining-count) entry per
    /// drop.
    @discardableResult
    public func punsubscribe(channel: Channel, from pattern: String?) -> [(String, Int)] {
        let id = ObjectIdentifier(channel)
        lock.lock(); defer { lock.unlock() }
        guard let (sub, current) = ownedPatterns[id] else { return [] }
        var results: [(String, Int)] = []
        let targets: Set<String>
        if let p = pattern { targets = [p] } else { targets = current }
        var remaining = current
        for p in targets {
            psubscribers[p]?.remove(sub)
            if psubscribers[p]?.isEmpty == true { psubscribers.removeValue(forKey: p) }
            remaining.remove(p)
            results.append((p, remaining.count))
        }
        if remaining.isEmpty {
            ownedPatterns.removeValue(forKey: id)
        } else {
            ownedPatterns[id] = (sub, remaining)
        }
        return results
    }

    /// Number of distinct patterns currently registered (used by
    /// `PUBSUB NUMPAT`).
    public func numPatterns() -> Int {
        lock.lock(); defer { lock.unlock() }
        return psubscribers.count
    }

    // MARK: PUBLISH

    /// Delivers `payload` to every subscriber of channel `name`, plus
    /// every pattern subscriber whose glob matches `name`. Returns the
    /// number of recipients reached (channel + pattern).
    ///
    /// RESP2 subscribers receive a flat 3-element array (`*3`); RESP3
    /// subscribers receive an out-of-band push frame (`>3`) so the
    /// client can distinguish messages from reply-queue traffic.
    @discardableResult
    public func publish(_ payload: Data, to name: String) -> Int {
        // Snapshot the targets under the lock; do the actual writes
        // outside so we don't hold the lock across NIO event-loop work.
        var directSubs: [Subscriber] = []
        var patternHits: [(String, Subscriber)] = []
        lock.lock()
        directSubs = Array(subscribers[name] ?? [])
        for (pattern, subs) in psubscribers {
            if Self.glob(pattern, matches: name) {
                for s in subs { patternHits.append((pattern, s)) }
            }
        }
        lock.unlock()

        // Pre-compute the two possible wire frames for the direct
        // delivery; pattern delivery has its own per-pattern frame, so
        // we encode it per-message below.
        let messageFrame2 = RESPSerializer.encode(.array([
            .bulkString("message"),
            .bulkString(name),
            .bulkString(payload),
        ]))
        let messageFrame3 = RESPSerializer.encode(.push([
            .bulkString("message"),
            .bulkString(name),
            .bulkString(payload),
        ]))
        for sub in directSubs {
            let bytes = sub.protocolVersion >= 3 ? messageFrame3 : messageFrame2
            var buf = sub.channel.allocator.buffer(capacity: bytes.count)
            buf.writeBytes(bytes)
            sub.channel.writeAndFlush(NIOAny(buf), promise: nil)
        }
        for (pattern, sub) in patternHits {
            let payloadValue: RESPValue
            if sub.protocolVersion >= 3 {
                payloadValue = .push([
                    .bulkString("pmessage"),
                    .bulkString(pattern),
                    .bulkString(name),
                    .bulkString(payload),
                ])
            } else {
                payloadValue = .array([
                    .bulkString("pmessage"),
                    .bulkString(pattern),
                    .bulkString(name),
                    .bulkString(payload),
                ])
            }
            let pmessage = RESPSerializer.encode(payloadValue)
            var buf = sub.channel.allocator.buffer(capacity: pmessage.count)
            buf.writeBytes(pmessage)
            sub.channel.writeAndFlush(NIOAny(buf), promise: nil)
        }
        return directSubs.count + patternHits.count
    }

    /// Glob match against a Redis-style channel name. Matches the
    /// semantics used by `KEYS` (delegates to `KeyStore.compileGlob`).
    /// Failing to compile (malformed pattern) yields no match rather
    /// than crashing the broker.
    static func glob(_ pattern: String, matches name: String) -> Bool {
        guard let regex = try? KeyStore.compileGlob(pattern) else { return false }
        let ns = name as NSString
        return regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Returns the per-channel subscriber count, in the order asked.
    public func numSub(for names: [String]) -> [(String, Int)] {
        lock.lock(); defer { lock.unlock() }
        return names.map { ($0, subscribers[$0]?.count ?? 0) }
    }

    /// Channel names that have at least one subscriber.
    public func channels(matching pattern: String? = nil) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(subscribers.keys)
        guard let pat = pattern, !pat.isEmpty, pat != "*" else { return all }
        let regex = try KeyStore.compileGlob(pat)
        return all.filter { s in
            let ns = s as NSString
            return regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
        }
    }

    // MARK: - Sharded pub/sub (Redis 7)
    //
    // On single-node swiftka, SPUBLISH/SSUBSCRIBE behave like
    // PUBLISH/SUBSCRIBE but use a fully separate keyspace + the
    // `smessage` frame instead of `message`, so the two surfaces never
    // cross-deliver. Pattern subscriptions are NOT supported (Redis 7
    // also rejects SPSUBSCRIBE / glob patterns over the shard surface).

    @discardableResult
    public func ssubscribe(channel: Channel, to name: String, protocolVersion: Int = 2) -> Int {
        let id = ObjectIdentifier(channel)
        lock.lock(); defer { lock.unlock() }
        let sub: Subscriber
        if let existing = ownedShard[id] {
            sub = existing.0
            ownedShard[id] = (sub, existing.1.union([name]))
        } else {
            sub = Subscriber(channel: channel, protocolVersion: protocolVersion)
            ownedShard[id] = (sub, [name])
        }
        ssubscribers[name, default: []].insert(sub)
        return ownedShard[id]!.1.count
    }

    @discardableResult
    public func sunsubscribe(channel: Channel, from name: String?) -> [(String, Int)] {
        let id = ObjectIdentifier(channel)
        lock.lock(); defer { lock.unlock() }
        guard let (sub, current) = ownedShard[id] else { return [] }
        var results: [(String, Int)] = []
        let targets: Set<String>
        if let n = name { targets = [n] } else { targets = current }
        var remaining = current
        for n in targets {
            ssubscribers[n]?.remove(sub)
            if ssubscribers[n]?.isEmpty == true { ssubscribers.removeValue(forKey: n) }
            remaining.remove(n)
            results.append((n, remaining.count))
        }
        if remaining.isEmpty {
            ownedShard.removeValue(forKey: id)
        } else {
            ownedShard[id] = (sub, remaining)
        }
        return results
    }

    /// Delivers `payload` to every shard subscriber of channel `name`.
    /// Returns the number of recipients reached. RESP2 subscribers get
    /// a `*3` array starting with `smessage`; RESP3 subscribers get a
    /// `>3` push frame.
    @discardableResult
    public func spublish(_ payload: Data, to name: String) -> Int {
        var targets: [Subscriber] = []
        lock.lock()
        targets = Array(ssubscribers[name] ?? [])
        lock.unlock()
        let frame2 = RESPSerializer.encode(.array([
            .bulkString("smessage"),
            .bulkString(name),
            .bulkString(payload),
        ]))
        let frame3 = RESPSerializer.encode(.push([
            .bulkString("smessage"),
            .bulkString(name),
            .bulkString(payload),
        ]))
        for sub in targets {
            let bytes = sub.protocolVersion >= 3 ? frame3 : frame2
            var buf = sub.channel.allocator.buffer(capacity: bytes.count)
            buf.writeBytes(bytes)
            sub.channel.writeAndFlush(NIOAny(buf), promise: nil)
        }
        return targets.count
    }

    /// Per-channel shard subscriber count, in the order asked
    /// (used by `PUBSUB SHARDNUMSUB`).
    public func numShardSub(for names: [String]) -> [(String, Int)] {
        lock.lock(); defer { lock.unlock() }
        return names.map { ($0, ssubscribers[$0]?.count ?? 0) }
    }

    /// Shard channels with at least one subscriber, optionally filtered
    /// by glob pattern (used by `PUBSUB SHARDCHANNELS`).
    public func shardChannels(matching pattern: String? = nil) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(ssubscribers.keys)
        guard let pat = pattern, !pat.isEmpty, pat != "*" else { return all }
        let regex = try KeyStore.compileGlob(pat)
        return all.filter { s in
            let ns = s as NSString
            return regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
        }
    }
}
