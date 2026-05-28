import Foundation
import NIOCore

/// A parsed RESP command: name (upper-cased ASCII) + raw argument
/// bulks. Commands arrive over the wire as RESP arrays whose first
/// element is the command name. The dispatcher upper-cases the name
/// so case-insensitive lookups are O(1).
public struct RESPCommand: Sendable {
    public let name: String           // upper-case ASCII, e.g. "PING"
    public let args: [Data]           // remaining bulk-string args

    public init(name: String, args: [Data]) {
        self.name = name
        self.args = args
    }

    /// Decode a RESP array into a command. The first element must be a
    /// bulk string (the command name); subsequent elements are turned
    /// into their bulk-string bytes (nil bulks become empty `Data`).
    public static func decode(_ value: RESPValue) -> RESPCommand? {
        guard case .array(.some(let items)) = value, !items.isEmpty else {
            return nil
        }
        guard case .bulkString(.some(let nameData)) = items[0],
              let name = String(data: nameData, encoding: .utf8) else {
            return nil
        }
        var args: [Data] = []
        args.reserveCapacity(items.count - 1)
        for item in items.dropFirst() {
            switch item {
            case .bulkString(let data):
                args.append(data ?? Data())
            case .simpleString(let s):
                args.append(Data(s.utf8))
            case .integer(let i):
                args.append(Data(String(i).utf8))
            default:
                args.append(Data())
            }
        }
        return RESPCommand(name: name.uppercased(), args: args)
    }

    /// Returns argument at `index` decoded as UTF-8 text, or `nil`.
    public func textArg(_ index: Int) -> String? {
        guard args.indices.contains(index) else { return nil }
        return String(data: args[index], encoding: .utf8)
    }
}

/// Dispatches RESP commands. Phase 4 connection management plus
/// Phase 5 key commands (SET/GET/DEL/EXISTS/KEYS/TYPE/RENAME) — the
/// data-store commands require a backing ``KeyStore``, which may be
/// `nil` for embedding callers that only want PING/HELLO/etc.
public final class CommandDispatcher: @unchecked Sendable {
    /// Server-side fields surfaced by `HELLO`/`COMMAND DOCS`.
    public let serverName: String
    public let serverVersion: String
    public let keys: KeyStore?
    /// Optional pub/sub broker. When `nil`, SUBSCRIBE/PUBLISH return
    /// "ERR pub/sub not configured" (matching the data-store-missing
    /// pattern).
    public let pubsub: PubSubBroker?
    /// Optional client registry. When non-nil, the channel handler
    /// registers each connection on activation; `CLIENT INFO/LIST/KILL`
    /// surface that state. Without it, `CLIENT INFO` returns a static
    /// stub.
    public let clients: ClientRegistry?
    /// Optional `requirepass` value. When non-`nil`, every command
    /// other than `AUTH`/`HELLO`/`QUIT` returns `NOAUTH` until the
    /// client successfully authenticates. Matches `redis.conf`'s
    /// `requirepass` directive.
    public let requiredPassword: String?

    /// Optional ACL registry. When non-nil, `AUTH user password` is
    /// resolved against the registry and attached to the connection.
    /// Per-command authorization is checked via `state.aclUser`. When
    /// nil the dispatcher falls back to the legacy single-password
    /// behaviour driven by `requiredPassword`.
    public let acl: ACLStore?

    /// Optional script registry. When non-nil, EVAL/EVALSHA/SCRIPT
    /// resolve here; when nil they return "ERR scripting not
    /// configured". `swiftka-server` always wires one.
    public let scripts: ScriptStore?

    /// Optional state container — per-connection state goes here when
    /// later phases need it (selected DB, client name, etc.).
    public final class ConnectionState: @unchecked Sendable {
        public var name: String = ""           // CLIENT GETNAME/SETNAME
        public var selectedDB: Int = 0         // SELECT n

        /// MULTI/EXEC transaction state. `queued == nil` means no
        /// transaction is in progress. `queued == []` means MULTI was
        /// issued but no commands queued yet. Otherwise the array is
        /// the FIFO buffer of commands awaiting EXEC. Per Redis,
        /// transactions are per-connection.
        public var queued: [RESPCommand]?
        /// Set to true if a queued command was rejected (unknown name,
        /// arity error). EXEC then aborts with EXECABORT.
        public var queueAborted: Bool = false

        /// SwiftNIO channel reference set by ``RESPChannelHandler`` so
        /// SUBSCRIBE / PSUBSCRIBE can register with the broker. `nil`
        /// when the dispatcher is invoked from a non-NIO test path.
        public var channel: Channel?

        /// Phase 16 — WATCH-snapshotted versions for this connection.
        /// Populated by WATCH, cleared on EXEC/DISCARD/UNWATCH. Each
        /// entry is `(key → rkey.version at WATCH time, or -1 if the
        /// key was missing then)`.
        public var watched: [String: Int64] = [:]

        /// Phase 17 — set to `true` once the connection has supplied
        /// the correct password (via `AUTH` or `HELLO ... AUTH`). When
        /// the dispatcher has `requiredPassword == nil` this is
        /// effectively ignored.
        public var authenticated: Bool = false

        /// Phase 19 — RESP protocol version negotiated via HELLO. `2`
        /// is the default (RESP2 wire shape, flat arrays everywhere);
        /// `3` enables RESP3 features (push frames for pub/sub).
        public var protocolVersion: Int = 2

        /// Phase 30 — current ACL user. `nil` when no ACL store is
        /// wired or the connection hasn't authenticated yet. Set by
        /// `AUTH` / `HELLO ... AUTH`.
        public var aclUser: ACLStore.ACLUser?

        public init() {}
    }

    public init(serverName: String = "swiftka",
                serverVersion: String = SwiftKa.version,
                keys: KeyStore? = nil,
                pubsub: PubSubBroker? = nil,
                clients: ClientRegistry? = nil,
                requiredPassword: String? = nil,
                acl: ACLStore? = nil,
                scripts: ScriptStore? = nil) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.keys = keys
        self.pubsub = pubsub
        self.clients = clients
        self.requiredPassword = requiredPassword
        self.acl = acl
        self.scripts = scripts
    }

    /// Dispatches a single command and returns the wire reply.
    public func dispatch(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        // Phase 17 — authentication gate. When the server was started
        // with a `requirepass`, only AUTH / HELLO / QUIT / RESET are
        // allowed pre-auth. AUTH itself is handled below.
        if requiredPassword != nil && !state.authenticated {
            switch command.name {
            case "AUTH":
                return dispatchAUTH(command, state: state)
            case "HELLO", "QUIT", "RESET":
                break // fall through to the normal switch
            default:
                return .error("NOAUTH Authentication required.")
            }
        }
        // Phase 17 — once-past-the-gate handling for AUTH itself, so
        // that a client re-authing after WATCH/MULTI etc still gets
        // OK without going through the transaction queue.
        if command.name == "AUTH" {
            return dispatchAUTH(command, state: state)
        }
        // Phase 30 — ACL per-command authorization. When the connection
        // is bound to an explicit ACL user (via `AUTH user password`),
        // every command must be allowed by the user's `+/-cmd` rules.
        // The `default` user with `+@all` and the no-ACL path are
        // both transparent.
        if let user = state.aclUser, !user.allows(command: command.name) {
            // ACL itself + WHOAMI are always allowed so a connection
            // can at least introspect its own permissions.
            switch command.name {
            case "ACL", "WHOAMI", "AUTH", "HELLO", "QUIT", "RESET":
                break
            default:
                return .error("NOPERM this user has no permissions to run the '\(command.name.lowercased())' command")
            }
        }
        // Phase 12 — transaction handling. MULTI/EXEC/DISCARD always
        // bypass the queue; everything else queues if a transaction is
        // open and runs through `dispatchRaw` otherwise.
        switch command.name {
        case "MULTI":
            if state.queued != nil {
                return .error("ERR MULTI calls can not be nested")
            }
            state.queued = []
            state.queueAborted = false
            return .simpleString("OK")

        case "DISCARD":
            guard state.queued != nil else {
                return .error("ERR DISCARD without MULTI")
            }
            state.queued = nil
            state.queueAborted = false
            state.watched.removeAll()
            return .simpleString("OK")

        case "EXEC":
            guard let queued = state.queued else {
                return .error("ERR EXEC without MULTI")
            }
            // Clear transaction state regardless of outcome.
            let aborted = state.queueAborted
            state.queued = nil
            state.queueAborted = false
            if aborted {
                state.watched.removeAll()
                return .error("EXECABORT Transaction discarded because of previous errors.")
            }
            // Phase 16 — WATCH check. If any watched key's version
            // moved since WATCH was issued, abort the transaction by
            // returning a nil multibulk (Redis convention).
            if !state.watched.isEmpty {
                if let snapshot = try? keys?.snapshotVersions(of: Array(state.watched.keys)) {
                    for (key, watched) in state.watched {
                        if let current = snapshot[key], current != watched {
                            state.watched.removeAll()
                            return .array(nil)
                        }
                    }
                }
            }
            state.watched.removeAll()
            var replies: [RESPValue] = []
            replies.reserveCapacity(queued.count)
            for q in queued {
                replies.append(dispatchRaw(q, state: state))
            }
            return .array(replies)

        case "WATCH":
            // WATCH key [key ...]
            if state.queued != nil {
                return .error("ERR WATCH inside MULTI is not allowed")
            }
            guard let keys = keys else { return .error("ERR storage not configured") }
            let names = command.args.compactMap { String(data: $0, encoding: .utf8) }
            guard !names.isEmpty else {
                return .error("ERR wrong number of arguments for 'watch' command")
            }
            do {
                let snap = try keys.snapshotVersions(of: names)
                for (k, v) in snap { state.watched[k] = v }
                return .simpleString("OK")
            } catch { return .error("ERR \(error)") }

        case "UNWATCH":
            state.watched.removeAll()
            return .simpleString("OK")

        default:
            // Inside a transaction? Queue and reply +QUEUED.
            if state.queued != nil {
                if isKnownCommand(command.name) {
                    state.queued?.append(command)
                    return .simpleString("QUEUED")
                } else {
                    state.queueAborted = true
                    return .error("ERR unknown command '\(command.name)'")
                }
            }
            return dispatchRaw(command, state: state)
        }
    }

    /// True if `name` is a command swiftka knows how to dispatch.
    /// Cheap allowlist used by MULTI's enqueue path so that a bad
    /// command name aborts the transaction (matching Redis semantics).
    private func isKnownCommand(_ name: String) -> Bool {
        switch name {
        case "PING", "ECHO", "SELECT", "HELLO", "CLIENT", "COMMAND", "QUIT",
             "AUTH", "RESET",
             "ACL", "WHOAMI",
             "SET", "GET", "DEL", "EXISTS", "KEYS", "TYPE", "RENAME", "SCAN",
             "APPEND", "STRLEN", "INCR", "DECR", "INCRBY", "DECRBY",
             "GETRANGE", "SUBSTR", "SETRANGE", "GETSET", "GETDEL", "GETEX",
             "MGET", "MSET", "MSETNX", "SETNX", "SETEX", "PSETEX",
             "SETBIT", "GETBIT", "BITCOUNT", "BITPOS", "BITOP", "BITFIELD",
             "BITFIELD_RO",
             "PFADD", "PFCOUNT", "PFMERGE",
             "LPUSH", "RPUSH", "LPOP", "RPOP", "LLEN", "LRANGE", "LINDEX",
             "LSET", "LREM", "LINSERT", "LTRIM", "RPOPLPUSH", "BLPOP",
             "HSET", "HMSET", "HSETNX", "HGET", "HMGET", "HGETALL",
             "HKEYS", "HVALS", "HEXISTS", "HLEN", "HDEL", "HINCRBY", "HSCAN",
             "SADD", "SREM", "SISMEMBER", "SMEMBERS", "SCARD",
             "SPOP", "SRANDMEMBER", "SDIFF", "SINTER", "SUNION",
             "SDIFFSTORE", "SINTERSTORE", "SUNIONSTORE", "SMOVE", "SSCAN",
             "ZADD", "ZSCORE", "ZRANK", "ZREVRANK", "ZCARD", "ZCOUNT",
             "ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE", "ZINCRBY", "ZREM",
             "ZUNIONSTORE", "ZINTERSTORE", "ZSCAN",
             "GEOADD", "GEOPOS", "GEODIST", "GEOHASH",
             "GEOSEARCH", "GEORADIUSBYMEMBER",
             "EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT",
             "TTL", "PTTL", "PERSIST",
             "SUBSCRIBE", "UNSUBSCRIBE", "PSUBSCRIBE", "PUNSUBSCRIBE",
             "PUBLISH", "PUBSUB",
             "SSUBSCRIBE", "SUNSUBSCRIBE", "SPUBLISH",
             "DBSIZE", "FLUSHDB", "FLUSHALL",
             "OBJECT", "DEBUG", "CLUSTER", "INFO", "TIME", "CONFIG",
             "SLOWLOG", "MEMORY", "LATENCY",
             "WAIT", "FAILOVER",
             "EVAL", "EVALSHA", "SCRIPT", "FUNCTION",
             "XADD", "XLEN", "XRANGE", "XREVRANGE", "XREAD", "XDEL", "XTRIM",
             "XGROUP", "XREADGROUP", "XACK", "XPENDING", "XCLAIM",
             "XAUTOCLAIM", "XINFO",
             "WATCH", "UNWATCH":
            return true
        default:
            return false
        }
    }

    /// Pre-Phase-12 dispatch: pretends MULTI/EXEC don't exist. This is
    /// the path invoked for each queued command from EXEC, and for
    /// every command outside a transaction.
    private func dispatchRaw(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        switch command.name {
        case "PING":
            // PING [msg]
            if let msg = command.textArg(0) {
                return .bulkString(msg)
            }
            return .simpleString("PONG")

        case "ECHO":
            guard let msg = command.textArg(0) else {
                return .error("ERR wrong number of arguments for 'echo' command")
            }
            return .bulkString(msg)

        case "SELECT":
            // RESP db isolation is faked: every db number simply
            // records itself on the connection. Real Redis allows
            // SELECT 0..15; swiftka accepts any non-negative integer
            // and stores it for tests / clients that send SELECT.
            guard let raw = command.textArg(0), let n = Int(raw), n >= 0 else {
                return .error("ERR invalid DB index")
            }
            state.selectedDB = n
            return .simpleString("OK")

        case "HELLO":
            // HELLO [proto [AUTH user pw] [SETNAME name]]
            // RESP2 and RESP3 are both supported as of Phase 19.
            var requestedProto = 2
            if let raw = command.textArg(0) {
                switch raw {
                case "2": requestedProto = 2
                case "3": requestedProto = 3
                default:
                    return .error("NOPROTO sorry, this protocol version is not supported.")
                }
            }
            // Phase 17 — parse optional AUTH/SETNAME flags. Only AUTH
            // is honored when requirepass is set; SETNAME just updates
            // state.name.
            var i = 1
            while i < command.args.count {
                let flag = command.textArg(i)?.uppercased() ?? ""
                switch flag {
                case "AUTH":
                    guard i + 2 < command.args.count,
                          let user = command.textArg(i + 1),
                          let pw = command.textArg(i + 2) else {
                        return .error("ERR Syntax error in HELLO AUTH")
                    }
                    // Phase 30 — try the ACL store first; fall back to
                    // the legacy single-password path against
                    // requirepass when the ACL lookup misses.
                    if let acl = acl, let u = acl.authenticate(name: user, password: pw) {
                        state.authenticated = true
                        state.aclUser = u
                    } else if let want = requiredPassword, want == pw {
                        state.authenticated = true
                        state.aclUser = acl?.user(named: "default")
                    } else if requiredPassword == nil && acl == nil {
                        // No auth is configured at all — accept whatever.
                        state.authenticated = true
                    } else {
                        return .error("WRONGPASS invalid username-password pair or user is disabled.")
                    }
                    i += 3
                case "SETNAME":
                    guard i + 1 < command.args.count,
                          let n = command.textArg(i + 1) else {
                        return .error("ERR Syntax error in HELLO SETNAME")
                    }
                    state.name = n
                    i += 2
                default:
                    return .error("ERR Syntax error in HELLO")
                }
            }
            // If `requirepass` is set and HELLO didn't authenticate,
            // we still return the server hello but later commands will
            // be blocked by the AUTH gate.
            state.protocolVersion = requestedProto
            let helloFields: [RESPKeyValue] = [
                RESPKeyValue(.bulkString("server"),  .bulkString(serverName)),
                RESPKeyValue(.bulkString("version"), .bulkString(serverVersion)),
                RESPKeyValue(.bulkString("proto"),   .integer(Int64(requestedProto))),
                RESPKeyValue(.bulkString("id"),      .integer(0)),
                RESPKeyValue(.bulkString("mode"),    .bulkString("standalone")),
                RESPKeyValue(.bulkString("role"),    .bulkString("master")),
                RESPKeyValue(.bulkString("modules"), .array(Optional<[RESPValue]>.some([]))),
            ]
            if requestedProto == 3 {
                return .map(helloFields)
            }
            // RESP2: flatten key/value pairs into an array.
            var flat: [RESPValue] = []
            flat.reserveCapacity(helloFields.count * 2)
            for f in helloFields { flat.append(f.key); flat.append(f.value) }
            return .array(flat)

        case "CLIENT":
            return dispatchCLIENT(command, state: state)

        case "COMMAND":
            return dispatchCOMMAND(command)

        case "QUIT":
            return .simpleString("OK")

        case "RESET":
            // Per Redis: returns +RESET\r\n and clears all per-connection
            // transaction / watch / subscription / client-name state.
            // Re-auth is required if requirepass is set.
            state.queued = nil
            state.queueAborted = false
            state.watched.removeAll()
            state.name = ""
            state.selectedDB = 0
            if let ch = state.channel, let broker = pubsub {
                broker.removeChannel(ch)
            }
            if requiredPassword != nil {
                state.authenticated = false
            }
            state.aclUser = nil
            return .simpleString("RESET")

        // Phase 30 — ACL.
        case "ACL":     return dispatchACL(command, state: state)
        case "WHOAMI":  return dispatchWHOAMI(state: state)

        // Phase 31 — scripting (EVAL/EVALSHA/SCRIPT/FUNCTION).
        case "EVAL":     return dispatchEVAL(command, state: state, byHash: false)
        case "EVALSHA":  return dispatchEVAL(command, state: state, byHash: true)
        case "SCRIPT":   return dispatchSCRIPT(command, state: state)
        case "FUNCTION": return dispatchFUNCTION(command)

        // Phase 5 — key-management commands. These require a backing
        // KeyStore; without one we surface the same wire error Redis
        // returns when an unknown command is sent.
        case "SET":     return dispatchSET(command)
        case "GET":     return dispatchGET(command)
        case "DEL":     return dispatchDEL(command)
        case "EXISTS":  return dispatchEXISTS(command)
        case "KEYS":    return dispatchKEYS(command)
        case "TYPE":    return dispatchTYPE(command)
        case "RENAME":  return dispatchRENAME(command)
        case "SCAN":    return dispatchSCAN(command)

        // Phase 6 — string-typed commands.
        case "APPEND":   return dispatchAPPEND(command)
        case "STRLEN":   return dispatchSTRLEN(command)
        case "INCR":     return dispatchINCR(command, delta: 1)
        case "DECR":     return dispatchINCR(command, delta: -1)
        case "INCRBY":   return dispatchINCRBY(command, sign: 1)
        case "DECRBY":   return dispatchINCRBY(command, sign: -1)
        case "GETRANGE", "SUBSTR": return dispatchGETRANGE(command)
        case "SETRANGE": return dispatchSETRANGE(command)
        case "GETSET":   return dispatchGETSET(command)
        case "GETDEL":   return dispatchGETDEL(command)
        case "GETEX":    return dispatchGETEX(command)
        case "MGET":     return dispatchMGET(command)
        case "MSET":     return dispatchMSET(command)
        case "MSETNX":   return dispatchMSETNX(command)
        case "SETNX":    return dispatchSETNX(command)
        case "SETEX":    return dispatchSETEX(command, unit: .seconds)
        case "PSETEX":   return dispatchSETEX(command, unit: .milliseconds)

        // Phase 27 — bit-level string commands.
        case "SETBIT":      return dispatchSETBIT(command)
        case "GETBIT":      return dispatchGETBIT(command)
        case "BITCOUNT":    return dispatchBITCOUNT(command)
        case "BITPOS":      return dispatchBITPOS(command)
        case "BITOP":       return dispatchBITOP(command)
        case "BITFIELD":    return dispatchBITFIELD(command, readOnly: false)
        case "BITFIELD_RO": return dispatchBITFIELD(command, readOnly: true)

        // Phase 29 — HyperLogLog.
        case "PFADD":   return dispatchPFADD(command)
        case "PFCOUNT": return dispatchPFCOUNT(command)
        case "PFMERGE": return dispatchPFMERGE(command)

        // Phase 7 — list-typed commands.
        case "LPUSH":     return dispatchPUSH(command, head: true)
        case "RPUSH":     return dispatchPUSH(command, head: false)
        case "LPOP":      return dispatchPOP(command, head: true)
        case "RPOP":      return dispatchPOP(command, head: false)
        case "LLEN":      return dispatchLLEN(command)
        case "LRANGE":    return dispatchLRANGE(command)
        case "LINDEX":    return dispatchLINDEX(command)
        case "LSET":      return dispatchLSET(command)
        case "LREM":      return dispatchLREM(command)
        case "LINSERT":   return dispatchLINSERT(command)
        case "LTRIM":     return dispatchLTRIM(command)
        case "RPOPLPUSH": return dispatchRPOPLPUSH(command)
        case "BLPOP":     return dispatchBLPOP(command)

        // Phase 8 — hash-typed commands.
        case "HSET":     return dispatchHSET(command)
        case "HMSET":    return dispatchHMSET(command)
        case "HSETNX":   return dispatchHSETNX(command)
        case "HGET":     return dispatchHGET(command)
        case "HMGET":    return dispatchHMGET(command)
        case "HGETALL":  return dispatchHGETALL(command)
        case "HKEYS":    return dispatchHKEYS(command)
        case "HVALS":    return dispatchHVALS(command)
        case "HEXISTS":  return dispatchHEXISTS(command)
        case "HLEN":     return dispatchHLEN(command)
        case "HDEL":     return dispatchHDEL(command)
        case "HINCRBY":  return dispatchHINCRBY(command)
        case "HSCAN":    return dispatchHSCAN(command)

        // Phase 9 — set-typed commands.
        case "SADD":         return dispatchSADD(command)
        case "SREM":         return dispatchSREM(command)
        case "SISMEMBER":    return dispatchSISMEMBER(command)
        case "SMEMBERS":     return dispatchSMEMBERS(command)
        case "SCARD":        return dispatchSCARD(command)
        case "SPOP":         return dispatchSPOP(command)
        case "SRANDMEMBER":  return dispatchSRANDMEMBER(command)
        case "SDIFF":        return dispatchSCombo(command, op: .diff)
        case "SINTER":       return dispatchSCombo(command, op: .inter)
        case "SUNION":       return dispatchSCombo(command, op: .union)
        case "SDIFFSTORE":   return dispatchSComboStore(command, op: .diff)
        case "SINTERSTORE":  return dispatchSComboStore(command, op: .inter)
        case "SUNIONSTORE":  return dispatchSComboStore(command, op: .union)
        case "SMOVE":        return dispatchSMOVE(command)
        case "SSCAN":        return dispatchSSCAN(command)

        // Phase 10 — sorted-set commands.
        case "ZADD":          return dispatchZADD(command)
        case "ZSCORE":        return dispatchZSCORE(command)
        case "ZRANK":         return dispatchZRANK(command, reverse: false)
        case "ZREVRANK":      return dispatchZRANK(command, reverse: true)
        case "ZCARD":         return dispatchZCARD(command)
        case "ZCOUNT":        return dispatchZCOUNT(command)
        case "ZRANGE":        return dispatchZRANGE(command, reverse: false)
        case "ZREVRANGE":     return dispatchZRANGE(command, reverse: true)
        case "ZRANGEBYSCORE": return dispatchZRANGEBYSCORE(command, reverse: false)
        case "ZINCRBY":       return dispatchZINCRBY(command)
        case "ZREM":          return dispatchZREM(command)
        case "ZUNIONSTORE":   return dispatchZComboStore(command, intersect: false)
        case "ZINTERSTORE":   return dispatchZComboStore(command, intersect: true)
        case "ZSCAN":         return dispatchZSCAN(command)

        // Phase 28 — Redis Geo.
        case "GEOADD":            return dispatchGEOADD(command)
        case "GEOPOS":            return dispatchGEOPOS(command)
        case "GEODIST":           return dispatchGEODIST(command)
        case "GEOHASH":           return dispatchGEOHASH(command)
        case "GEOSEARCH":         return dispatchGEOSEARCH(command, byMember: false)
        case "GEORADIUSBYMEMBER": return dispatchGEOSEARCH(command, byMember: true)

        // Phase 11 — TTL commands.
        case "EXPIRE":     return dispatchEXPIRE(command, unit: .seconds, absolute: false)
        case "PEXPIRE":    return dispatchEXPIRE(command, unit: .milliseconds, absolute: false)
        case "EXPIREAT":   return dispatchEXPIRE(command, unit: .seconds, absolute: true)
        case "PEXPIREAT":  return dispatchEXPIRE(command, unit: .milliseconds, absolute: true)
        case "TTL":        return dispatchTTL(command, unit: .seconds)
        case "PTTL":       return dispatchTTL(command, unit: .milliseconds)
        case "PERSIST":    return dispatchPERSIST(command)

        // Phase 13 + 14 — pub/sub commands.
        case "SUBSCRIBE":    return dispatchSUBSCRIBE(command, state: state)
        case "UNSUBSCRIBE":  return dispatchUNSUBSCRIBE(command, state: state)
        case "PSUBSCRIBE":   return dispatchPSUBSCRIBE(command, state: state)
        case "PUNSUBSCRIBE": return dispatchPUNSUBSCRIBE(command, state: state)
        case "PUBLISH":      return dispatchPUBLISH(command)
        case "PUBSUB":       return dispatchPUBSUB(command)

        // Phase 26 — sharded pub/sub (Redis 7).
        case "SSUBSCRIBE":   return dispatchSSUBSCRIBE(command, state: state)
        case "SUNSUBSCRIBE": return dispatchSUNSUBSCRIBE(command, state: state)
        case "SPUBLISH":     return dispatchSPUBLISH(command)

        // Phase 18 — introspection / compat stubs.
        case "DBSIZE":       return dispatchDBSIZE()
        case "FLUSHDB", "FLUSHALL": return dispatchFLUSHDB()
        case "OBJECT":       return dispatchOBJECT(command)
        case "DEBUG":        return dispatchDEBUG(command)
        case "CLUSTER":      return dispatchCLUSTER(command)
        case "INFO":         return dispatchINFO(command)
        case "TIME":         return dispatchTIME()
        case "CONFIG":       return dispatchCONFIG(command)
        // Phase 24 — diagnostic / observability stubs.
        case "SLOWLOG":      return dispatchSLOWLOG(command)
        case "MEMORY":       return dispatchMEMORY(command)
        case "LATENCY":      return dispatchLATENCY(command)
        // Phase 26 — replication primitives (no-op stubs on single-node).
        case "WAIT":         return dispatchWAIT(command)
        case "FAILOVER":     return dispatchFAILOVER(command)

        // Phase 20 — streams.
        case "XADD":      return dispatchXADD(command)
        case "XLEN":      return dispatchXLEN(command)
        case "XRANGE":    return dispatchXRANGE(command, reverse: false)
        case "XREVRANGE": return dispatchXRANGE(command, reverse: true)
        case "XREAD":     return dispatchXREAD(command)
        case "XDEL":      return dispatchXDEL(command)
        case "XTRIM":     return dispatchXTRIM(command)

        // Phase 23 — stream consumer groups.
        case "XGROUP":     return dispatchXGROUP(command)
        case "XREADGROUP": return dispatchXREADGROUP(command)
        case "XACK":       return dispatchXACK(command)
        case "XPENDING":   return dispatchXPENDING(command)
        case "XCLAIM":     return dispatchXCLAIM(command)
        case "XAUTOCLAIM": return dispatchXAUTOCLAIM(command)
        case "XINFO":      return dispatchXINFO(command)

        
        default:
            return .error("ERR unknown command '\(command.name)'")
        }
    }

    // MARK: - Phase 5 commands

    private func dispatchSET(_ command: RESPCommand) -> RESPValue {
        guard command.args.count >= 2 else {
            return .error("ERR wrong number of arguments for 'set' command")
        }
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR storage not configured")
        }
        do {
            try keys.set(key: key, value: command.args[1])
            return .simpleString("OK")
        } catch let e as KeyStoreError {
            return .error(String(describing: e))
        } catch {
            return .error("ERR \(error)")
        }
    }

    private func dispatchGET(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'get' command")
        }
        do {
            if let v = try keys.get(key: key) {
                return .bulkString(v)
            }
            return .bulkString(nil)
        } catch let e as KeyStoreError {
            return .error(String(describing: e))
        } catch {
            return .error("ERR \(error)")
        }
    }

    private func dispatchDEL(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, !command.args.isEmpty else {
            return .error("ERR wrong number of arguments for 'del' command")
        }
        let names = command.args.compactMap { String(data: $0, encoding: .utf8) }
        do {
            let removed = try keys.del(keys: names)
            return .integer(Int64(removed))
        } catch {
            return .error("ERR \(error)")
        }
    }

    private func dispatchEXISTS(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, !command.args.isEmpty else {
            return .error("ERR wrong number of arguments for 'exists' command")
        }
        let names = command.args.compactMap { String(data: $0, encoding: .utf8) }
        do {
            let n = try keys.exists(keys: names)
            return .integer(Int64(n))
        } catch {
            return .error("ERR \(error)")
        }
    }

    private func dispatchKEYS(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let pattern = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'keys' command")
        }
        do {
            let matches = try keys.keys(pattern: pattern)
            return .array(matches.map { .bulkString($0) })
        } catch {
            return .error("ERR \(error)")
        }
    }

    private func dispatchTYPE(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'type' command")
        }
        do {
            let t = try keys.type(key: key)
            return .simpleString(t)
        } catch {
            return .error("ERR \(error)")
        }
    }

    private func dispatchRENAME(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              let src = command.textArg(0),
              let dst = command.textArg(1) else {
            return .error("ERR wrong number of arguments for 'rename' command")
        }
        do {
            try keys.rename(src: src, dst: dst)
            return .simpleString("OK")
        } catch let e as KeyStoreError {
            return .error(String(describing: e))
        } catch {
            return .error("ERR \(error)")
        }
    }

    /// `SCAN cursor [MATCH pattern] [COUNT n] [TYPE t]` — Phase 15.
    private func dispatchSCAN(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              let cursorRaw = command.textArg(0),
              let cursor = Int64(cursorRaw) else {
            return .error("ERR wrong number of arguments for 'scan' command")
        }
        var match: String?
        var count: Int?
        var type: RedkaType?
        var i = 1
        while i + 1 < command.args.count {
            let flag = command.textArg(i)?.uppercased()
            switch flag {
            case "MATCH":
                match = command.textArg(i + 1)
            case "COUNT":
                count = command.textArg(i + 1).flatMap(Int.init)
            case "TYPE":
                let raw = command.textArg(i + 1)?.lowercased()
                switch raw {
                case "string": type = .string
                case "list":   type = .list
                case "set":    type = .set
                case "hash":   type = .hash
                case "zset":   type = .zset
                default: return .error("ERR unknown TYPE filter '\(raw ?? "")'")
                }
            default:
                return .error("ERR syntax error")
            }
            i += 2
        }
        do {
            let (next, names) = try keys.scan(cursor: cursor,
                                              match: match,
                                              count: count,
                                              type: type)
            return .array([
                .bulkString(String(next)),
                .array(names.map(RESPValue.bulkString)),
            ])
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    // MARK: - Phase 6 commands

    enum TTLUnit { case seconds, milliseconds }

    private func dispatchAPPEND(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'append' command")
        }
        do {
            let n = try keys.append(key: key, value: command.args[1])
            return .integer(Int64(n))
        } catch let e as KeyStoreError {
            return .error(String(describing: e))
        } catch { return .error("ERR \(error)") }
    }

    private func dispatchSTRLEN(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'strlen' command")
        }
        do { return .integer(Int64(try keys.strlen(key: key))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchINCR(_ command: RESPCommand, delta: Int64) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(try keys.incrBy(key: key, delta: delta)) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchINCRBY(_ command: RESPCommand, sign: Int64) -> RESPValue {
        guard let keys = keys,
              let key = command.textArg(0),
              let raw = command.textArg(1),
              let n = Int64(raw) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(try keys.incrBy(key: key, delta: sign * n)) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchGETRANGE(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              let key = command.textArg(0),
              let lo = command.textArg(1).flatMap(Int.init),
              let hi = command.textArg(2).flatMap(Int.init) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .bulkString(try keys.getRange(key: key, start: lo, end: hi)) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSETRANGE(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              command.args.count >= 3,
              let key = command.textArg(0),
              let offset = command.textArg(1).flatMap(Int.init) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            let n = try keys.setRange(key: key, offset: offset, value: command.args[2])
            return .integer(Int64(n))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchGETSET(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            if let prev = try keys.getSet(key: key, value: command.args[1]) {
                return .bulkString(prev)
            }
            return .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchGETDEL(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            if let v = try keys.getDel(key: key) { return .bulkString(v) }
            return .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchGETEX(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        // Parse optional [EX s | PX ms | EXAT s | PXAT ms | PERSIST]
        var option: KeyStore.GetExOption = .none
        if command.args.count >= 2 {
            let flag = command.textArg(1)?.uppercased() ?? ""
            switch flag {
            case "PERSIST":
                option = .persist
            case "EX", "PX", "EXAT", "PXAT":
                guard let raw = command.textArg(2), let v = Int64(raw) else {
                    return .error("ERR value is not an integer or out of range")
                }
                switch flag {
                case "EX":   option = .ex(v)
                case "PX":   option = .px(v)
                case "EXAT": option = .exAt(v)
                case "PXAT": option = .pxAt(v)
                default:     break
                }
            default:
                return .error("ERR syntax error")
            }
        }
        do {
            if let v = try keys.getEx(key: key, option: option) { return .bulkString(v) }
            return .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchMGET(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, !command.args.isEmpty else {
            return .error("ERR wrong number of arguments")
        }
        let names = command.args.compactMap { String(data: $0, encoding: .utf8) }
        do {
            let values = try keys.mget(keys: names)
            return .array(values.map { v in v.map(RESPValue.bulkString) ?? .bulkString(nil) })
        } catch { return .error("ERR \(error)") }
    }

    private func dispatchMSET(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys else { return .error("ERR storage not configured") }
        if command.args.count < 2 || command.args.count % 2 != 0 {
            return .error("ERR wrong number of arguments for 'mset' command")
        }
        var pairs: [(String, Data)] = []
        var i = 0
        while i < command.args.count {
            guard let key = String(data: command.args[i], encoding: .utf8) else {
                return .error("ERR invalid key encoding")
            }
            pairs.append((key, command.args[i + 1]))
            i += 2
        }
        do { try keys.mset(pairs: pairs); return .simpleString("OK") }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchMSETNX(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys else { return .error("ERR storage not configured") }
        if command.args.count < 2 || command.args.count % 2 != 0 {
            return .error("ERR wrong number of arguments for 'msetnx' command")
        }
        var pairs: [(String, Data)] = []
        var i = 0
        while i < command.args.count {
            guard let key = String(data: command.args[i], encoding: .utf8) else {
                return .error("ERR invalid key encoding")
            }
            pairs.append((key, command.args[i + 1]))
            i += 2
        }
        do { return .integer(try keys.msetnx(pairs: pairs) ? 1 : 0) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSETNX(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(try keys.setnx(key: key, value: command.args[1]) ? 1 : 0) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSETEX(_ command: RESPCommand, unit: TTLUnit) -> RESPValue {
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0),
              let raw = command.textArg(1),
              let n = Int64(raw) else {
            return .error("ERR wrong number of arguments")
        }
        if n <= 0 { return .error("ERR invalid expire time") }
        do {
            switch unit {
            case .seconds:      try keys.setex(key: key, seconds: n, value: command.args[2])
            case .milliseconds: try keys.psetex(key: key, milliseconds: n, value: command.args[2])
            }
            return .simpleString("OK")
        } catch { return .error("ERR \(error)") }
    }

    private func dispatchCLIENT(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'client' command")
        }
        // Live-state helpers — write through to ClientRegistry so
        // CLIENT INFO/LIST reflect the connection's current state.
        let live: ClientRegistry.ClientInfo? = {
            guard let registry = clients, let ch = state.channel else { return nil }
            return registry.info(for: ch)
        }()
        switch sub {
        case "GETNAME":
            return .bulkString(state.name)
        case "SETNAME":
            guard let name = command.textArg(1) else {
                return .error("ERR wrong number of arguments for 'client|setname' command")
            }
            // Validate per Redis: name can't contain spaces or newlines.
            if name.contains(" ") || name.contains("\n") {
                return .error("ERR Client names cannot contain spaces, newlines or special characters.")
            }
            state.name = name
            live?.name = name
            return .simpleString("OK")
        case "ID":
            return .integer(live?.id ?? 0)
        case "NO-EVICT", "NO-TOUCH":
            // Accept ON/OFF silently — swiftka has no eviction yet.
            return .simpleString("OK")
        case "REPLY":
            // ON/OFF/SKIP. swiftka v0 doesn't suppress replies; just
            // accept ON, and OFF/SKIP for compatibility (the latter
            // would need pipelined-write suppression).
            return .simpleString("OK")
        case "PAUSE", "UNPAUSE":
            // Stop accepting new commands for N ms. swiftka v0 ignores
            // the argument since there's no per-event-loop quiesce
            // mechanism yet. Returning +OK keeps tooling happy.
            return .simpleString("OK")
        case "SETINFO":
            // CLIENT SETINFO LIB-NAME <name>  /  LIB-VER <version>
            guard let key = command.textArg(1)?.uppercased(),
                  let value = command.textArg(2) else {
                return .error("ERR wrong number of arguments for 'client|setinfo'")
            }
            switch key {
            case "LIB-NAME": live?.library = value
            case "LIB-VER":  live?.libraryVersion = value
            default: return .error("ERR Unrecognized option")
            }
            return .simpleString("OK")
        case "INFO":
            // Single-line summary for the current connection.
            guard let registry = clients, let info = live else {
                return .bulkString("id=0 addr=unknown name= proto=2")
            }
            return .bulkString(registry.formattedLine(info))
        case "LIST":
            // Multi-line summary for every active connection.
            guard let registry = clients else {
                return .bulkString("")
            }
            let lines = registry.snapshot().map { registry.formattedLine($0) }
            return .bulkString(lines.joined(separator: "\n"))
        case "KILL":
            // Two forms: legacy `CLIENT KILL addr:port` and filter form
            // `CLIENT KILL ID <id>`. We support the ID form fully and
            // ADDR by linear scan of the registry.
            guard let registry = clients else { return .integer(0) }
            if command.args.count == 2, let arg = command.textArg(1), !arg.uppercased().elementsEqual("ID") {
                // Legacy `CLIENT KILL addr`.
                let killed = registry.snapshot().filter { $0.addr == arg }
                for k in killed { _ = registry.kill(id: k.id) }
                return killed.isEmpty
                    ? .error("ERR No such client")
                    : .simpleString("OK")
            }
            // Filter form: CLIENT KILL [ID id] [ADDR addr] [SKIPME yes|no]
            var idFilter: Int64?
            var addrFilter: String?
            var skipMe = true
            var i = 1
            while i + 1 <= command.args.count {
                let flag = command.textArg(i)?.uppercased()
                switch flag {
                case "ID":
                    idFilter = command.textArg(i + 1).flatMap(Int64.init); i += 2
                case "ADDR":
                    addrFilter = command.textArg(i + 1); i += 2
                case "SKIPME":
                    skipMe = (command.textArg(i + 1)?.lowercased() == "yes"); i += 2
                default:
                    i += 1
                }
            }
            var count = 0
            let selfId = live?.id
            for c in registry.snapshot() {
                if let f = idFilter, c.id != f { continue }
                if let f = addrFilter, c.addr != f { continue }
                if skipMe, c.id == selfId { continue }
                if registry.kill(id: c.id) { count += 1 }
            }
            return .integer(Int64(count))
        case "HELP":
            return .array([
                .bulkString("CLIENT GETNAME -- Return the name of the current connection."),
                .bulkString("CLIENT SETNAME <name> -- Assign the name to the current connection."),
                .bulkString("CLIENT ID -- Return the numeric id of the current connection."),
                .bulkString("CLIENT INFO -- Return single-line info for the current connection."),
                .bulkString("CLIENT LIST -- Return info for all currently-connected clients."),
                .bulkString("CLIENT KILL [ID id|ADDR addr] [SKIPME yes|no] -- Close a connection."),
                .bulkString("CLIENT NO-EVICT ON|OFF -- Protect connection from eviction (no-op)."),
                .bulkString("CLIENT REPLY ON|OFF|SKIP -- Control reply delivery (always ON)."),
                .bulkString("CLIENT PAUSE <ms> -- Pause new command processing (no-op)."),
                .bulkString("CLIENT UNPAUSE -- Resume processing (no-op)."),
                .bulkString("CLIENT SETINFO LIB-NAME|LIB-VER <value> -- Record library identity."),
                .bulkString("CLIENT HELP -- This help."),
            ])
        default:
            return .error("ERR unknown CLIENT subcommand '\(sub)'")
        }
    }

    private func dispatchCOMMAND(_ command: RESPCommand) -> RESPValue {
        guard let sub = command.textArg(0)?.uppercased() else {
            // COMMAND with no args returns the full command list —
            // swiftka's catalogue is tiny in Phase 4, so we return an
            // empty array. Real clients only call this for tab-completion.
            return .array(Optional<[RESPValue]>.some([]))
        }
        switch sub {
        case "DOCS":
            // Real Redis returns a map of name -> {summary, since, ...}
            // encoded as a flat RESP array. We emit one entry per known
            // command so `redis-cli` doesn't choke on tab completion.
            let docs: [(String, String)] = [
                ("ping",    "Returns PONG (or echoes its argument)."),
                ("echo",    "Echoes its argument."),
                ("select",  "Selects a logical database."),
                ("hello",   "Switches protocol version and returns server info."),
                ("client",  "Subcommand router for client connection management."),
                ("command", "Returns documentation for swiftka commands."),
                ("quit",    "Closes the connection."),
            ]
            var out: [RESPValue] = []
            out.reserveCapacity(docs.count * 2)
            for (name, summary) in docs {
                out.append(.bulkString(name))
                out.append(.array([
                    .bulkString("summary"), .bulkString(summary),
                ]))
            }
            return .array(out)
        case "COUNT":
            return .integer(7)
        default:
            return .array(Optional<[RESPValue]>.some([]))
        }
    }

    // MARK: - Phase 27 — bit-level string commands

    private func dispatchSETBIT(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count == 3,
              let key = command.textArg(0),
              let offset = command.textArg(1).flatMap(Int.init),
              let value = command.textArg(2).flatMap(Int.init) else {
            return .error("ERR wrong number of arguments for 'setbit' command")
        }
        do { return .integer(Int64(try keys.setBit(key: key, offset: offset, value: value))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchGETBIT(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count == 2,
              let key = command.textArg(0),
              let offset = command.textArg(1).flatMap(Int.init) else {
            return .error("ERR wrong number of arguments for 'getbit' command")
        }
        do { return .integer(Int64(try keys.getBit(key: key, offset: offset))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchBITCOUNT(_ command: RESPCommand) -> RESPValue {
        // BITCOUNT key [start end [BYTE|BIT]]
        guard let keys = keys, command.args.count >= 1,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'bitcount' command")
        }
        var start: Int? = nil
        var end: Int? = nil
        var unit: KeyStore.BitRangeUnit = .byte
        if command.args.count >= 3 {
            guard let lo = command.textArg(1).flatMap(Int.init),
                  let hi = command.textArg(2).flatMap(Int.init) else {
                return .error("ERR value is not an integer or out of range")
            }
            start = lo
            end = hi
        } else if command.args.count == 2 {
            return .error("ERR syntax error")
        }
        if command.args.count >= 4 {
            switch command.textArg(3)?.uppercased() {
            case "BYTE": unit = .byte
            case "BIT":  unit = .bit
            default:     return .error("ERR syntax error")
            }
        }
        do {
            let n = try keys.bitCount(key: key, start: start, end: end, unit: unit)
            return .integer(Int64(n))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchBITPOS(_ command: RESPCommand) -> RESPValue {
        // BITPOS key bit [start [end [BYTE|BIT]]]
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0),
              let bit = command.textArg(1).flatMap(Int.init) else {
            return .error("ERR wrong number of arguments for 'bitpos' command")
        }
        var start: Int? = nil
        var end: Int? = nil
        var unit: KeyStore.BitRangeUnit = .byte
        if command.args.count >= 3 {
            guard let lo = command.textArg(2).flatMap(Int.init) else {
                return .error("ERR value is not an integer or out of range")
            }
            start = lo
        }
        if command.args.count >= 4 {
            guard let hi = command.textArg(3).flatMap(Int.init) else {
                return .error("ERR value is not an integer or out of range")
            }
            end = hi
        }
        if command.args.count >= 5 {
            switch command.textArg(4)?.uppercased() {
            case "BYTE": unit = .byte
            case "BIT":  unit = .bit
            default:     return .error("ERR syntax error")
            }
        }
        do {
            let pos = try keys.bitPos(key: key, target: bit, start: start, end: end, unit: unit)
            return .integer(Int64(pos))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchBITOP(_ command: RESPCommand) -> RESPValue {
        // BITOP op dest key [key ...]
        guard let keys = keys, command.args.count >= 3,
              let opName = command.textArg(0)?.uppercased(),
              let dest = command.textArg(1) else {
            return .error("ERR wrong number of arguments for 'bitop' command")
        }
        let op: KeyStore.BitOp
        switch opName {
        case "AND": op = .and
        case "OR":  op = .or
        case "XOR": op = .xor
        case "NOT": op = .not
        default:    return .error("ERR syntax error")
        }
        let sources = command.args.dropFirst(2).compactMap { String(data: $0, encoding: .utf8) }
        do {
            let n = try keys.bitOp(op, dest: dest, sources: sources)
            return .integer(Int64(n))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    /// `BITFIELD key [GET type offset] [SET type offset value]
    ///                [INCRBY type offset delta] [OVERFLOW WRAP|SAT|FAIL] ...`
    /// `BITFIELD_RO key [GET type offset] ...` — read-only variant that
    /// rejects SET / INCRBY / OVERFLOW.
    private func dispatchBITFIELD(_ command: RESPCommand, readOnly: Bool) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'bitfield' command")
        }
        var ops: [KeyStore.BitFieldOp] = []
        var i = 1
        while i < command.args.count {
            guard let sub = command.textArg(i)?.uppercased() else {
                return .error("ERR syntax error")
            }
            switch sub {
            case "GET":
                guard i + 2 < command.args.count,
                      let typeRaw = command.textArg(i + 1),
                      let offset = parseBitFieldOffset(command.textArg(i + 2), type: typeRaw) else {
                    return .error("ERR syntax error")
                }
                guard let type = parseBitFieldType(typeRaw) else {
                    return .error("ERR Invalid bitfield type. Use something like i16 u8. Note that u64 is not supported but i64 is.")
                }
                ops.append(.get(type: type, offset: offset))
                i += 3
            case "SET":
                if readOnly { return .error("ERR BITFIELD_RO only supports the GET subcommand") }
                guard i + 3 < command.args.count,
                      let typeRaw = command.textArg(i + 1),
                      let offset = parseBitFieldOffset(command.textArg(i + 2), type: typeRaw),
                      let raw = command.textArg(i + 3),
                      let value = Int64(raw) else {
                    return .error("ERR syntax error")
                }
                guard let type = parseBitFieldType(typeRaw) else {
                    return .error("ERR Invalid bitfield type. Use something like i16 u8. Note that u64 is not supported but i64 is.")
                }
                ops.append(.set(type: type, offset: offset, value: value))
                i += 4
            case "INCRBY":
                if readOnly { return .error("ERR BITFIELD_RO only supports the GET subcommand") }
                guard i + 3 < command.args.count,
                      let typeRaw = command.textArg(i + 1),
                      let offset = parseBitFieldOffset(command.textArg(i + 2), type: typeRaw),
                      let raw = command.textArg(i + 3),
                      let delta = Int64(raw) else {
                    return .error("ERR syntax error")
                }
                guard let type = parseBitFieldType(typeRaw) else {
                    return .error("ERR Invalid bitfield type. Use something like i16 u8. Note that u64 is not supported but i64 is.")
                }
                ops.append(.incrBy(type: type, offset: offset, delta: delta))
                i += 4
            case "OVERFLOW":
                if readOnly { return .error("ERR BITFIELD_RO only supports the GET subcommand") }
                guard i + 1 < command.args.count,
                      let mode = command.textArg(i + 1)?.uppercased() else {
                    return .error("ERR syntax error")
                }
                switch mode {
                case "WRAP": ops.append(.overflow(.wrap))
                case "SAT":  ops.append(.overflow(.sat))
                case "FAIL": ops.append(.overflow(.fail))
                default:     return .error("ERR syntax error")
                }
                i += 2
            default:
                return .error("ERR syntax error")
            }
        }
        do {
            let results = try keys.bitField(key: key, ops: ops)
            return .array(results.map { v -> RESPValue in
                if let n = v { return .integer(n) }
                return .bulkString(nil)
            })
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    /// Parse a BITFIELD type token like "u8" / "i16" / "i64".
    private func parseBitFieldType(_ token: String) -> KeyStore.BitFieldType? {
        guard token.count >= 2 else { return nil }
        let first = token.first!
        let signed: Bool
        switch first {
        case "i", "I": signed = true
        case "u", "U": signed = false
        default: return nil
        }
        guard let bits = Int(token.dropFirst()) else { return nil }
        if signed {
            guard bits >= 1 && bits <= 64 else { return nil }
        } else {
            guard bits >= 1 && bits <= 63 else { return nil }
        }
        return KeyStore.BitFieldType(signed: signed, bits: bits)
    }

    /// Parse a BITFIELD offset, honouring the leading `#` shorthand that
    /// multiplies by the type's width (`#0` for first field, `#1` for
    /// second, etc).
    private func parseBitFieldOffset(_ raw: String?, type: String) -> Int? {
        guard var s = raw else { return nil }
        var multiplier = 1
        if s.hasPrefix("#") {
            s.removeFirst()
            // Multiplier is the type's bit width.
            guard s.count >= 1, let t = parseBitFieldType(type) else { return nil }
            multiplier = t.bits
        }
        guard let n = Int(s), n >= 0 else { return nil }
        return n * multiplier
    }

    // MARK: - Phase 29 — HyperLogLog

    private func dispatchPFADD(_ command: RESPCommand) -> RESPValue {
        // PFADD key [element ...]
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'pfadd' command")
        }
        let elements = Array(command.args.dropFirst())
        do { return .integer(Int64(try keys.pfAdd(key: key, elements: elements))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchPFCOUNT(_ command: RESPCommand) -> RESPValue {
        // PFCOUNT key [key ...]
        guard let keys = keys, command.args.count >= 1 else {
            return .error("ERR wrong number of arguments for 'pfcount' command")
        }
        let names = command.args.compactMap { String(data: $0, encoding: .utf8) }
        do { return .integer(Int64(try keys.pfCount(keys: names))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchPFMERGE(_ command: RESPCommand) -> RESPValue {
        // PFMERGE dest [source ...]
        guard let keys = keys, command.args.count >= 1,
              let dest = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'pfmerge' command")
        }
        let sources = command.args.dropFirst().compactMap { String(data: $0, encoding: .utf8) }
        do { try keys.pfMerge(dest: dest, sources: Array(sources)); return .simpleString("OK") }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    // MARK: - Phase 7 commands

    private func dispatchPUSH(_ command: RESPCommand, head: Bool) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        let values = Array(command.args.dropFirst())
        do {
            let n = head ? try keys.lpush(key: key, values: values)
                         : try keys.rpush(key: key, values: values)
            return .integer(Int64(n))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchPOP(_ command: RESPCommand, head: Bool) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        // Optional count argument (Redis 6.2+).
        let count = command.textArg(1).flatMap(Int.init) ?? 1
        let multi = command.args.count >= 2
        do {
            let popped = head ? try keys.lpop(key: key, count: count)
                              : try keys.rpop(key: key, count: count)
            if multi {
                if popped.isEmpty { return .array(nil) }
                return .array(popped.map(RESPValue.bulkString))
            } else {
                return popped.first.map(RESPValue.bulkString) ?? .bulkString(nil)
            }
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchLLEN(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(Int64(try keys.llen(key: key))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchLRANGE(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              let key = command.textArg(0),
              let start = command.textArg(1).flatMap(Int.init),
              let stop  = command.textArg(2).flatMap(Int.init) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            let items = try keys.lrange(key: key, start: start, stop: stop)
            return .array(items.map(RESPValue.bulkString))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchLINDEX(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              let key = command.textArg(0),
              let idx = command.textArg(1).flatMap(Int.init) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            if let v = try keys.lindex(key: key, index: idx) { return .bulkString(v) }
            return .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchLSET(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              command.args.count >= 3,
              let key = command.textArg(0),
              let idx = command.textArg(1).flatMap(Int.init) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            try keys.lset(key: key, index: idx, value: command.args[2])
            return .simpleString("OK")
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchLREM(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              command.args.count >= 3,
              let key = command.textArg(0),
              let count = command.textArg(1).flatMap(Int.init) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            let n = try keys.lrem(key: key, count: count, element: command.args[2])
            return .integer(Int64(n))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchLINSERT(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              command.args.count >= 4,
              let key = command.textArg(0),
              let whereStr = command.textArg(1)?.uppercased(),
              let position = KeyStore.LInsertWhere(rawValue: whereStr) else {
            return .error("ERR syntax error")
        }
        do {
            let n = try keys.linsert(key: key,
                                     position: position,
                                     pivot: command.args[2],
                                     value: command.args[3])
            return .integer(Int64(n))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchLTRIM(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              let key = command.textArg(0),
              let start = command.textArg(1).flatMap(Int.init),
              let stop  = command.textArg(2).flatMap(Int.init) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            try keys.ltrim(key: key, start: start, stop: stop)
            return .simpleString("OK")
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchRPOPLPUSH(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              let src = command.textArg(0),
              let dst = command.textArg(1) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            if let v = try keys.rpopLpush(src: src, dst: dst) { return .bulkString(v) }
            return .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchBLPOP(_ command: RESPCommand) -> RESPValue {
        // Last arg is the timeout (in seconds, possibly fractional);
        // swiftka v0 ignores it and behaves non-blocking.
        guard let keys = keys, command.args.count >= 2 else {
            return .error("ERR wrong number of arguments")
        }
        let names = command.args.dropLast().compactMap { String(data: $0, encoding: .utf8) }
        do {
            if let (key, value) = try keys.blpop(keys: Array(names)) {
                return .array([.bulkString(key), .bulkString(value)])
            }
            return .array(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    // MARK: - Phase 8 commands

    private func dispatchHSET(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'hset' command")
        }
        let rest = command.args.dropFirst()
        if rest.count % 2 != 0 {
            return .error("ERR wrong number of arguments for 'hset' command")
        }
        var pairs: [(String, Data)] = []
        var i = rest.startIndex
        while i < rest.endIndex {
            guard let field = String(data: rest[i], encoding: .utf8) else {
                return .error("ERR invalid field encoding")
            }
            pairs.append((field, rest[i + 1]))
            i = rest.index(i, offsetBy: 2)
        }
        do { return .integer(Int64(try keys.hset(key: key, pairs: pairs))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchHMSET(_ command: RESPCommand) -> RESPValue {
        // Identical surface to HSET but returns +OK\r\n (legacy Redis).
        guard case .integer = dispatchHSET(command) else {
            // Propagate the error.
            return dispatchHSET(command)
        }
        return .simpleString("OK")
    }

    private func dispatchHSETNX(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0),
              let field = command.textArg(1) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            let set = try keys.hsetnx(key: key, field: field, value: command.args[2])
            return .integer(set ? 1 : 0)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchHGET(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              let key = command.textArg(0),
              let field = command.textArg(1) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            if let v = try keys.hget(key: key, field: field) { return .bulkString(v) }
            return .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchHMGET(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        let fields = command.args.dropFirst().compactMap { String(data: $0, encoding: .utf8) }
        do {
            let vs = try keys.hmget(key: key, fields: Array(fields))
            return .array(vs.map { v in v.map(RESPValue.bulkString) ?? .bulkString(nil) })
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchHGETALL(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            let pairs = try keys.hgetall(key: key)
            var out: [RESPValue] = []
            out.reserveCapacity(pairs.count * 2)
            for (f, v) in pairs {
                out.append(.bulkString(f))
                out.append(.bulkString(v))
            }
            return .array(out)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchHKEYS(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .array(try keys.hkeys(key: key).map(RESPValue.bulkString)) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchHVALS(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .array(try keys.hvals(key: key).map(RESPValue.bulkString)) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchHEXISTS(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              let key = command.textArg(0),
              let field = command.textArg(1) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(try keys.hexists(key: key, field: field) ? 1 : 0) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchHLEN(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(Int64(try keys.hlen(key: key))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchHDEL(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        let fields = command.args.dropFirst().compactMap { String(data: $0, encoding: .utf8) }
        do { return .integer(Int64(try keys.hdel(key: key, fields: Array(fields)))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchHINCRBY(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys,
              let key = command.textArg(0),
              let field = command.textArg(1),
              let raw = command.textArg(2),
              let n = Int64(raw) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(try keys.hincrBy(key: key, field: field, delta: n)) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchHSCAN(_ command: RESPCommand) -> RESPValue {
        // HSCAN key cursor [MATCH pattern] [COUNT n]
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0),
              let cursor = command.textArg(1).flatMap(Int64.init) else {
            return .error("ERR wrong number of arguments")
        }
        var match: String?
        var count: Int?
        var i = 2
        while i + 1 < command.args.count {
            let flag = command.textArg(i)?.uppercased()
            switch flag {
            case "MATCH": match = command.textArg(i + 1)
            case "COUNT": count = command.textArg(i + 1).flatMap(Int.init)
            default: return .error("ERR syntax error")
            }
            i += 2
        }
        do {
            let (nextCursor, pairs) = try keys.hscan2(key: key, cursor: cursor, match: match, count: count)
            var flat: [RESPValue] = []
            for (f, v) in pairs {
                flat.append(.bulkString(f))
                flat.append(.bulkString(v))
            }
            return .array([.bulkString(String(nextCursor)), .array(flat)])
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    // MARK: - Phase 9 commands

    enum SCombinator { case diff, inter, union }

    private func dispatchSADD(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        let members = Array(command.args.dropFirst())
        do { return .integer(Int64(try keys.sadd(key: key, members: members))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSREM(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        let members = Array(command.args.dropFirst())
        do { return .integer(Int64(try keys.srem(key: key, members: members))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSISMEMBER(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(try keys.sismember(key: key, member: command.args[1]) ? 1 : 0) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSMEMBERS(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .array(try keys.smembers(key: key).map(RESPValue.bulkString)) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSCARD(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(Int64(try keys.scard(key: key))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSPOP(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        let multi = command.args.count >= 2
        let count = command.textArg(1).flatMap(Int.init) ?? 1
        do {
            let popped = try keys.spop(key: key, count: count)
            if multi { return .array(popped.map(RESPValue.bulkString)) }
            return popped.first.map(RESPValue.bulkString) ?? .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSRANDMEMBER(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        let multi = command.args.count >= 2
        let count = command.textArg(1).flatMap(Int.init)
        do {
            let picked = try keys.srandmember(key: key, count: count)
            if multi { return .array(picked.map(RESPValue.bulkString)) }
            return picked.first.map(RESPValue.bulkString) ?? .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSCombo(_ command: RESPCommand, op: SCombinator) -> RESPValue {
        guard let keys = keys, !command.args.isEmpty else {
            return .error("ERR wrong number of arguments")
        }
        let names = command.args.compactMap { String(data: $0, encoding: .utf8) }
        do {
            let result: [Data]
            switch op {
            case .diff:  result = try keys.sdiff(keys: names)
            case .inter: result = try keys.sinter(keys: names)
            case .union: result = try keys.sunion(keys: names)
            }
            return .array(result.map(RESPValue.bulkString))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSComboStore(_ command: RESPCommand, op: SCombinator) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let dst = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        let names = command.args.dropFirst().compactMap { String(data: $0, encoding: .utf8) }
        do {
            let n: Int
            switch op {
            case .diff:  n = try keys.sdiffstore(dst: dst,  keys: Array(names))
            case .inter: n = try keys.sinterstore(dst: dst, keys: Array(names))
            case .union: n = try keys.sunionstore(dst: dst, keys: Array(names))
            }
            return .integer(Int64(n))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSMOVE(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 3,
              let src = command.textArg(0),
              let dst = command.textArg(1) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(try keys.smove(src: src, dst: dst, member: command.args[2]) ? 1 : 0) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchSSCAN(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0),
              let cursor = command.textArg(1).flatMap(Int64.init) else {
            return .error("ERR wrong number of arguments")
        }
        var match: String?
        var count: Int?
        var i = 2
        while i + 1 < command.args.count {
            switch command.textArg(i)?.uppercased() {
            case "MATCH": match = command.textArg(i + 1)
            case "COUNT": count = command.textArg(i + 1).flatMap(Int.init)
            default: return .error("ERR syntax error")
            }
            i += 2
        }
        do {
            let (next, items) = try keys.sscan2(key: key, cursor: cursor, match: match, count: count)
            return .array([.bulkString(String(next)),
                           .array(items.map(RESPValue.bulkString))])
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    // MARK: - Phase 10 commands

    private func dispatchZADD(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        let rest = command.args.dropFirst()
        if rest.count % 2 != 0 {
            return .error("ERR syntax error")
        }
        var pairs: [(Double, Data)] = []
        var i = rest.startIndex
        while i < rest.endIndex {
            guard let raw = String(data: rest[i], encoding: .utf8),
                  let score = Double(raw) else {
                return .error("ERR value is not a valid float")
            }
            pairs.append((score, rest[i + 1]))
            i = rest.index(i, offsetBy: 2)
        }
        do { return .integer(Int64(try keys.zadd(key: key, members: pairs))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchZSCORE(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            if let s = try keys.zscore(key: key, member: command.args[1]) {
                return .bulkString(formatScore(s))
            }
            return .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchZRANK(_ command: RESPCommand, reverse: Bool) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            if let r = try keys.zrank(key: key, member: command.args[1], reverse: reverse) {
                return .integer(Int64(r))
            }
            return .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchZCARD(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(Int64(try keys.zcard(key: key))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchZCOUNT(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0),
              let minS = command.textArg(1), let maxS = command.textArg(2),
              let mn = parseScoreBound(minS), let mx = parseScoreBound(maxS) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(Int64(try keys.zcount(key: key, min: mn, max: mx))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchZRANGE(_ command: RESPCommand, reverse: Bool) -> RESPValue {
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0),
              let start = command.textArg(1).flatMap(Int.init),
              let stop  = command.textArg(2).flatMap(Int.init) else {
            return .error("ERR wrong number of arguments")
        }
        let withScores = command.args.count > 3 &&
                         command.textArg(3)?.uppercased() == "WITHSCORES"
        do {
            let items = try keys.zrange(key: key, start: start, stop: stop, reverse: reverse)
            if withScores {
                var out: [RESPValue] = []
                for m in items {
                    out.append(.bulkString(m.elem))
                    out.append(.bulkString(formatScore(m.score)))
                }
                return .array(out)
            }
            return .array(items.map { .bulkString($0.elem) })
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchZRANGEBYSCORE(_ command: RESPCommand, reverse: Bool) -> RESPValue {
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0),
              let minS = command.textArg(1), let maxS = command.textArg(2),
              let mn = parseScoreBound(minS), let mx = parseScoreBound(maxS) else {
            return .error("ERR wrong number of arguments")
        }
        var withScores = false
        var offset = 0
        var count: Int?
        var i = 3
        while i < command.args.count {
            let flag = command.textArg(i)?.uppercased() ?? ""
            switch flag {
            case "WITHSCORES":
                withScores = true; i += 1
            case "LIMIT":
                guard i + 2 < command.args.count,
                      let o = command.textArg(i + 1).flatMap(Int.init),
                      let c = command.textArg(i + 2).flatMap(Int.init) else {
                    return .error("ERR syntax error")
                }
                offset = o; count = c; i += 3
            default:
                return .error("ERR syntax error")
            }
        }
        do {
            let items = try keys.zrangeByScore(key: key, min: mn, max: mx,
                                               offset: offset, count: count,
                                               reverse: reverse)
            if withScores {
                var out: [RESPValue] = []
                for m in items {
                    out.append(.bulkString(m.elem))
                    out.append(.bulkString(formatScore(m.score)))
                }
                return .array(out)
            }
            return .array(items.map { .bulkString($0.elem) })
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchZINCRBY(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0),
              let raw = command.textArg(1),
              let delta = Double(raw) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            let next = try keys.zincrBy(key: key, delta: delta, member: command.args[2])
            return .bulkString(formatScore(next))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchZREM(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        let members = Array(command.args.dropFirst())
        do { return .integer(Int64(try keys.zrem(key: key, members: members))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchZComboStore(_ command: RESPCommand, intersect: Bool) -> RESPValue {
        // ZUNIONSTORE/ZINTERSTORE dst numkeys key [key ...] [AGGREGATE SUM|MIN|MAX]
        guard let keys = keys, command.args.count >= 3,
              let dst = command.textArg(0),
              let numkeys = command.textArg(1).flatMap(Int.init),
              numkeys >= 1,
              command.args.count >= 2 + numkeys else {
            return .error("ERR wrong number of arguments")
        }
        let names = (0..<numkeys).compactMap { i in command.textArg(2 + i) }
        var agg: KeyStore.ZSetAggregate = .sum
        var i = 2 + numkeys
        while i < command.args.count {
            switch command.textArg(i)?.uppercased() {
            case "AGGREGATE":
                guard i + 1 < command.args.count,
                      let mode = command.textArg(i + 1)?.uppercased(),
                      let a = KeyStore.ZSetAggregate(rawValue: mode) else {
                    return .error("ERR syntax error")
                }
                agg = a; i += 2
            case "WEIGHTS":
                // Skip past WEIGHTS arg list; swiftka treats every
                // weight as 1.0 in v0.
                i += 1 + numkeys
            default:
                return .error("ERR syntax error")
            }
        }
        do {
            let n: Int
            if intersect {
                n = try keys.zinterstore(dst: dst, keys: names, aggregate: agg)
            } else {
                n = try keys.zunionstore(dst: dst, keys: names, aggregate: agg)
            }
            return .integer(Int64(n))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchZSCAN(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0),
              let cursor = command.textArg(1).flatMap(Int64.init) else {
            return .error("ERR wrong number of arguments")
        }
        var match: String?
        var count: Int?
        var i = 2
        while i + 1 < command.args.count {
            switch command.textArg(i)?.uppercased() {
            case "MATCH": match = command.textArg(i + 1)
            case "COUNT": count = command.textArg(i + 1).flatMap(Int.init)
            default: return .error("ERR syntax error")
            }
            i += 2
        }
        do {
            let (next, items) = try keys.zscan2(key: key, cursor: cursor, match: match, count: count)
            var flat: [RESPValue] = []
            for (elem, score) in items {
                flat.append(.bulkString(elem))
                flat.append(.bulkString(formatScore(score)))
            }
            return .array([.bulkString(String(next)), .array(flat)])
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    /// Score formatting matches Redis: integral values render without
    /// a decimal point; non-integral values use the shortest unambiguous
    /// representation.
    private func formatScore(_ s: Double) -> String {
        if s.isNaN { return "nan" }
        if s.isInfinite { return s > 0 ? "inf" : "-inf" }
        if s == s.rounded() && abs(s) < 1e15 {
            return String(Int64(s))
        }
        return String(s)
    }

    /// Parses ZRANGEBYSCORE/ZCOUNT bounds. Supports `-inf`, `+inf`,
    /// `inf`, plain doubles, and Redis's `(` exclusive prefix (which
    /// swiftka treats as inclusive for v0).
    private func parseScoreBound(_ s: String) -> Double? {
        var t = s
        if t.hasPrefix("(") { t = String(t.dropFirst()) }
        switch t.lowercased() {
        case "-inf": return -.infinity
        case "+inf", "inf": return .infinity
        default: return Double(t)
        }
    }

    // MARK: - Phase 11 commands

    private func dispatchEXPIRE(_ command: RESPCommand,
                                unit: TTLUnit,
                                absolute: Bool) -> RESPValue {
        guard let keys = keys,
              let key = command.textArg(0),
              let raw = command.textArg(1),
              let n = Int64(raw) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            let ok: Bool
            switch (absolute, unit) {
            case (false, .seconds):      ok = try keys.expire(key: key, ttlMS: n * 1000)
            case (false, .milliseconds): ok = try keys.expire(key: key, ttlMS: n)
            case (true,  .seconds):      ok = try keys.expireAt(key: key, atMS: n * 1000)
            case (true,  .milliseconds): ok = try keys.expireAt(key: key, atMS: n)
            }
            return .integer(ok ? 1 : 0)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchTTL(_ command: RESPCommand, unit: TTLUnit) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do {
            switch unit {
            case .seconds:      return .integer(try keys.ttl(key: key))
            case .milliseconds: return .integer(try keys.pttl(key: key))
            }
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchPERSIST(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(try keys.persist(key: key) ? 1 : 0) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    // MARK: - Phase 28 — Redis Geo

    private func dispatchGEOADD(_ command: RESPCommand) -> RESPValue {
        // GEOADD key [NX|XX] [CH] lon lat member [lon lat member ...]
        // swiftka v0.10.0 accepts but ignores the NX/XX/CH flags — the
        // underlying ZADD always upserts; we don't surface CH-style
        // changed-count reporting yet.
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'geoadd' command")
        }
        var i = 1
        // Skip any leading flag tokens (NX / XX / CH).
        while i < command.args.count {
            guard let token = command.textArg(i)?.uppercased() else { break }
            if token == "NX" || token == "XX" || token == "CH" { i += 1 } else { break }
        }
        guard (command.args.count - i) >= 3,
              (command.args.count - i) % 3 == 0 else {
            return .error("ERR syntax error")
        }
        var items: [(Double, Double, Data)] = []
        while i + 2 < command.args.count {
            guard let lon = command.textArg(i).flatMap(Double.init),
                  let lat = command.textArg(i + 1).flatMap(Double.init) else {
                return .error("ERR value is not a valid float")
            }
            items.append((lon, lat, command.args[i + 2]))
            i += 3
        }
        do {
            let added = try keys.geoAdd(key: key, items: items)
            return .integer(Int64(added))
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchGEOPOS(_ command: RESPCommand) -> RESPValue {
        // GEOPOS key member [member ...]
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'geopos' command")
        }
        let members = Array(command.args.dropFirst())
        do {
            let positions = try keys.geoPos(key: key, members: members)
            return .array(positions.map { p -> RESPValue in
                if let (lon, lat) = p {
                    return .array([
                        .bulkString(Self.formatGeoCoord(lon)),
                        .bulkString(Self.formatGeoCoord(lat)),
                    ])
                }
                return .array(Optional<[RESPValue]>.none)
            })
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchGEODIST(_ command: RESPCommand) -> RESPValue {
        // GEODIST key member1 member2 [unit]
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'geodist' command")
        }
        var unit: GeoUnit = .meters
        if command.args.count >= 4 {
            guard let u = command.textArg(3).flatMap(GeoUnit.parse) else {
                return .error("ERR unsupported unit provided. please use M, KM, FT, MI")
            }
            unit = u
        }
        do {
            if let d = try keys.geoDist(key: key, a: command.args[1], b: command.args[2], unit: unit) {
                return .bulkString(Self.formatGeoDistance(d))
            }
            return .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchGEOHASH(_ command: RESPCommand) -> RESPValue {
        // GEOHASH key member [member ...]
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'geohash' command")
        }
        let members = Array(command.args.dropFirst())
        do {
            let hashes = try keys.geoHash(key: key, members: members)
            return .array(hashes.map { h -> RESPValue in
                if let s = h { return .bulkString(s) }
                return .bulkString(nil)
            })
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    /// GEOSEARCH key FROMMEMBER name | FROMLONLAT lon lat
    ///           BYRADIUS radius unit | BYBOX width height unit
    ///           [ASC|DESC] [COUNT count [ANY]]
    ///           [WITHCOORD] [WITHDIST] [WITHHASH]
    ///
    /// `byMember` selects the deprecated `GEORADIUSBYMEMBER` shape which
    /// implicitly anchors on a member and takes a positional radius +
    /// unit before optional flags.
    private func dispatchGEOSEARCH(_ command: RESPCommand, byMember: Bool) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'geosearch' command")
        }
        var anchor: (lon: Double, lat: Double)? = nil
        var shape: KeyStore.GeoShape? = nil
        var ascending = true
        var count: Int? = nil
        var countAny = false
        var withCoord = false
        var withDist = false
        var withHash = false
        var i = 1
        if byMember {
            // GEORADIUSBYMEMBER key member radius unit [...]
            guard command.args.count >= 4,
                  let m = command.args.dropFirst(1).first,
                  let r = command.textArg(2).flatMap(Double.init),
                  let u = command.textArg(3).flatMap(GeoUnit.parse) else {
                return .error("ERR syntax error")
            }
            do {
                let positions = try keys.geoPos(key: key, members: [m])
                guard let p = positions.first, let coord = p else {
                    return .error("ERR could not decode requested zset member")
                }
                anchor = coord
            } catch let e as KeyStoreError { return .error(String(describing: e)) }
            catch { return .error("ERR \(error)") }
            shape = .radius(meters: r / u.perMeter)
            i = 4
        }
        while i < command.args.count {
            guard let tok = command.textArg(i)?.uppercased() else {
                return .error("ERR syntax error")
            }
            switch tok {
            case "FROMMEMBER":
                guard i + 1 < command.args.count else { return .error("ERR syntax error") }
                let m = command.args[i + 1]
                do {
                    let positions = try keys.geoPos(key: key, members: [m])
                    guard let p = positions.first, let coord = p else {
                        return .error("ERR could not decode requested zset member")
                    }
                    anchor = coord
                } catch let e as KeyStoreError { return .error(String(describing: e)) }
                catch { return .error("ERR \(error)") }
                i += 2
            case "FROMLONLAT":
                guard i + 2 < command.args.count,
                      let lon = command.textArg(i + 1).flatMap(Double.init),
                      let lat = command.textArg(i + 2).flatMap(Double.init) else {
                    return .error("ERR syntax error")
                }
                anchor = (lon, lat)
                i += 3
            case "BYRADIUS":
                guard i + 2 < command.args.count,
                      let r = command.textArg(i + 1).flatMap(Double.init),
                      let u = command.textArg(i + 2).flatMap(GeoUnit.parse) else {
                    return .error("ERR syntax error")
                }
                shape = .radius(meters: r / u.perMeter)
                i += 3
            case "BYBOX":
                guard i + 3 < command.args.count,
                      let w = command.textArg(i + 1).flatMap(Double.init),
                      let h = command.textArg(i + 2).flatMap(Double.init),
                      let u = command.textArg(i + 3).flatMap(GeoUnit.parse) else {
                    return .error("ERR syntax error")
                }
                shape = .box(widthMeters: w / u.perMeter, heightMeters: h / u.perMeter)
                i += 4
            case "ASC":
                ascending = true; i += 1
            case "DESC":
                ascending = false; i += 1
            case "COUNT":
                guard i + 1 < command.args.count,
                      let c = command.textArg(i + 1).flatMap(Int.init), c > 0 else {
                    return .error("ERR syntax error")
                }
                count = c
                i += 2
                if i < command.args.count, command.textArg(i)?.uppercased() == "ANY" {
                    countAny = true
                    i += 1
                }
            case "WITHCOORD": withCoord = true; i += 1
            case "WITHDIST":  withDist = true;  i += 1
            case "WITHHASH":  withHash = true;  i += 1
            default:
                return .error("ERR syntax error")
            }
        }
        guard let anchorPt = anchor, let shape = shape else {
            return .error("ERR syntax error")
        }
        // Convert distance units back to the requested unit for the
        // WITHDIST output. For BYRADIUS / BYBOX we still report
        // distance in the unit the caller supplied; pull that from the
        // shape's source unit isn't preserved, so just default to
        // meters and the smoke test asserts meters.
        do {
            let matches = try keys.geoSearch(key: key, anchor: anchorPt, shape: shape,
                                             ascending: ascending,
                                             count: count, countAny: countAny)
            if !withCoord && !withDist && !withHash {
                return .array(matches.map { .bulkString($0.member) })
            }
            return .array(matches.map { m -> RESPValue in
                var row: [RESPValue] = [.bulkString(m.member)]
                if withDist {
                    row.append(.bulkString(Self.formatGeoDistance(m.distanceMeters)))
                }
                if withHash {
                    row.append(.integer(Int64(m.score)))
                }
                if withCoord {
                    row.append(.array([
                        .bulkString(Self.formatGeoCoord(m.lon)),
                        .bulkString(Self.formatGeoCoord(m.lat)),
                    ]))
                }
                return .array(row)
            })
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    /// Formats a coordinate with the 17-digit precision Redis uses on
    /// the wire (e.g. "-122.41940150000000236").
    private static func formatGeoCoord(_ v: Double) -> String {
        // 17 fractional digits is what real Redis prints. Trimming
        // trailing zeros breaks Redis-cli expected output, so keep them.
        return String(format: "%.17f", v)
    }

    /// Formats a distance with 4 fractional digits (Redis default).
    private static func formatGeoDistance(_ v: Double) -> String {
        return String(format: "%.4f", v)
    }

    // MARK: - Phase 13 commands

    private func dispatchSUBSCRIBE(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        guard let broker = pubsub else { return .error("ERR pub/sub not configured") }
        guard let channel = state.channel else {
            return .error("ERR SUBSCRIBE requires an active connection")
        }
        let names = command.args.compactMap { String(data: $0, encoding: .utf8) }
        guard !names.isEmpty else {
            return .error("ERR wrong number of arguments for 'subscribe' command")
        }
        // Redis sends one *3 reply per channel: ["subscribe", name, count].
        var replies: [RESPValue] = []
        for name in names {
            let count = broker.subscribe(channel: channel, to: name, protocolVersion: state.protocolVersion)
            replies.append(.array([
                .bulkString("subscribe"),
                .bulkString(name),
                .integer(Int64(count)),
            ]))
        }
        // Pack the responses as a single array. The chat protocol allows
        // pipelined frames so multiple subscribe acks could be sent
        // individually, but a flat array round-trips cleanly through
        // every redis client we tested. swiftka's smoke uses raw TCP
        // and asserts on the wire bytes.
        if replies.count == 1 { return replies[0] }
        var multi: [RESPValue] = []
        for r in replies { multi.append(r) }
        return .array(multi)
    }

    private func dispatchUNSUBSCRIBE(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        guard let broker = pubsub else { return .error("ERR pub/sub not configured") }
        guard let channel = state.channel else {
            return .error("ERR UNSUBSCRIBE requires an active connection")
        }
        let names: [String?]
        if command.args.isEmpty {
            names = [nil]
        } else {
            names = command.args.compactMap { String(data: $0, encoding: .utf8) }
        }
        var replies: [RESPValue] = []
        for name in names {
            let unsubbed = broker.unsubscribe(channel: channel, from: name)
            if unsubbed.isEmpty {
                // Redis still emits a triple even when no subs existed.
                replies.append(.array([
                    .bulkString("unsubscribe"),
                    .bulkString(nil),
                    .integer(0),
                ]))
            } else {
                for (n, remaining) in unsubbed {
                    replies.append(.array([
                        .bulkString("unsubscribe"),
                        .bulkString(n),
                        .integer(Int64(remaining)),
                    ]))
                }
            }
        }
        if replies.count == 1 { return replies[0] }
        return .array(replies)
    }

    private func dispatchPUBLISH(_ command: RESPCommand) -> RESPValue {
        guard let broker = pubsub else { return .error("ERR pub/sub not configured") }
        guard command.args.count >= 2,
              let name = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'publish' command")
        }
        let delivered = broker.publish(command.args[1], to: name)
        return .integer(Int64(delivered))
    }

    private func dispatchPSUBSCRIBE(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        guard let broker = pubsub else { return .error("ERR pub/sub not configured") }
        guard let channel = state.channel else {
            return .error("ERR PSUBSCRIBE requires an active connection")
        }
        let patterns = command.args.compactMap { String(data: $0, encoding: .utf8) }
        guard !patterns.isEmpty else {
            return .error("ERR wrong number of arguments for 'psubscribe' command")
        }
        var replies: [RESPValue] = []
        for p in patterns {
            let count = broker.psubscribe(channel: channel, to: p, protocolVersion: state.protocolVersion)
            replies.append(.array([
                .bulkString("psubscribe"),
                .bulkString(p),
                .integer(Int64(count)),
            ]))
        }
        if replies.count == 1 { return replies[0] }
        return .array(replies)
    }

    private func dispatchPUNSUBSCRIBE(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        guard let broker = pubsub else { return .error("ERR pub/sub not configured") }
        guard let channel = state.channel else {
            return .error("ERR PUNSUBSCRIBE requires an active connection")
        }
        let patterns: [String?]
        if command.args.isEmpty {
            patterns = [nil]
        } else {
            patterns = command.args.compactMap { String(data: $0, encoding: .utf8) }
        }
        var replies: [RESPValue] = []
        for p in patterns {
            let dropped = broker.punsubscribe(channel: channel, from: p)
            if dropped.isEmpty {
                replies.append(.array([
                    .bulkString("punsubscribe"),
                    .bulkString(nil),
                    .integer(0),
                ]))
            } else {
                for (name, remaining) in dropped {
                    replies.append(.array([
                        .bulkString("punsubscribe"),
                        .bulkString(name),
                        .integer(Int64(remaining)),
                    ]))
                }
            }
        }
        if replies.count == 1 { return replies[0] }
        return .array(replies)
    }

    private func dispatchPUBSUB(_ command: RESPCommand) -> RESPValue {
        guard let broker = pubsub else { return .error("ERR pub/sub not configured") }
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'pubsub' command")
        }
        switch sub {
        case "CHANNELS":
            let pattern = command.textArg(1)
            do {
                let names = try broker.channels(matching: pattern)
                return .array(names.map(RESPValue.bulkString))
            } catch {
                return .error("ERR \(error)")
            }
        case "NUMSUB":
            let names = command.args.dropFirst().compactMap { String(data: $0, encoding: .utf8) }
            let counts = broker.numSub(for: Array(names))
            var flat: [RESPValue] = []
            for (n, c) in counts {
                flat.append(.bulkString(n))
                flat.append(.integer(Int64(c)))
            }
            return .array(flat)
        case "NUMPAT":
            return .integer(Int64(broker.numPatterns()))
        case "SHARDCHANNELS":
            let pattern = command.textArg(1)
            do {
                let names = try broker.shardChannels(matching: pattern)
                return .array(names.map(RESPValue.bulkString))
            } catch {
                return .error("ERR \(error)")
            }
        case "SHARDNUMSUB":
            let names = command.args.dropFirst().compactMap { String(data: $0, encoding: .utf8) }
            let counts = broker.numShardSub(for: Array(names))
            var flat: [RESPValue] = []
            for (n, c) in counts {
                flat.append(.bulkString(n))
                flat.append(.integer(Int64(c)))
            }
            return .array(flat)
        default:
            return .error("ERR unknown PUBSUB subcommand '\(sub)'")
        }
    }

    // MARK: - Phase 26 — sharded pub/sub

    private func dispatchSSUBSCRIBE(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        guard let broker = pubsub else { return .error("ERR pub/sub not configured") }
        guard let channel = state.channel else {
            return .error("ERR SSUBSCRIBE requires an active connection")
        }
        let names = command.args.compactMap { String(data: $0, encoding: .utf8) }
        guard !names.isEmpty else {
            return .error("ERR wrong number of arguments for 'ssubscribe' command")
        }
        var replies: [RESPValue] = []
        for name in names {
            let count = broker.ssubscribe(channel: channel, to: name, protocolVersion: state.protocolVersion)
            replies.append(.array([
                .bulkString("ssubscribe"),
                .bulkString(name),
                .integer(Int64(count)),
            ]))
        }
        if replies.count == 1 { return replies[0] }
        return .array(replies)
    }

    private func dispatchSUNSUBSCRIBE(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        guard let broker = pubsub else { return .error("ERR pub/sub not configured") }
        guard let channel = state.channel else {
            return .error("ERR SUNSUBSCRIBE requires an active connection")
        }
        let names: [String?]
        if command.args.isEmpty {
            names = [nil]
        } else {
            names = command.args.compactMap { String(data: $0, encoding: .utf8) }
        }
        var replies: [RESPValue] = []
        for name in names {
            let dropped = broker.sunsubscribe(channel: channel, from: name)
            if dropped.isEmpty {
                replies.append(.array([
                    .bulkString("sunsubscribe"),
                    .bulkString(nil),
                    .integer(0),
                ]))
            } else {
                for (n, remaining) in dropped {
                    replies.append(.array([
                        .bulkString("sunsubscribe"),
                        .bulkString(n),
                        .integer(Int64(remaining)),
                    ]))
                }
            }
        }
        if replies.count == 1 { return replies[0] }
        return .array(replies)
    }

    private func dispatchSPUBLISH(_ command: RESPCommand) -> RESPValue {
        guard let broker = pubsub else { return .error("ERR pub/sub not configured") }
        guard command.args.count >= 2,
              let name = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'spublish' command")
        }
        let delivered = broker.spublish(command.args[1], to: name)
        return .integer(Int64(delivered))
    }

    // MARK: - Phase 26 — replication primitives (single-node stubs)

    /// `WAIT numreplicas timeout` — single-node swiftka has no replicas,
    /// so the answer is always 0 and we return immediately. Matches the
    /// Redis behavior of returning the count of acked replicas (here:
    /// none).
    private func dispatchWAIT(_ command: RESPCommand) -> RESPValue {
        // Validate the shape so misuse still surfaces as an error.
        guard command.args.count == 2,
              command.textArg(0).flatMap(Int.init) != nil,
              command.textArg(1).flatMap(Int.init) != nil else {
            return .error("ERR wrong number of arguments for 'wait' command")
        }
        return .integer(0)
    }

    /// `FAILOVER [TO host port [FORCE]] [ABORT] [TIMEOUT ms]` —
    /// single-node swiftka has nothing to fail over to. We accept the
    /// command shape and return +OK so orchestration scripts don't
    /// fall over.
    private func dispatchFAILOVER(_ command: RESPCommand) -> RESPValue {
        _ = command
        return .simpleString("OK")
    }

    // MARK: - Phase 17 — AUTH

    private func dispatchAUTH(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        // AUTH password           (legacy form, single-password —
        //                          checked ONLY against requiredPassword)
        // AUTH username password  (ACL form — looked up via the ACL
        //                          store when one is wired).
        switch command.args.count {
        case 1:
            guard let pw = command.textArg(0) else {
                return .error("ERR wrong number of arguments for 'auth' command")
            }
            guard let want = requiredPassword else {
                // Legacy Redis behaviour: without a requirepass, the
                // single-arg AUTH form returns this exact message.
                return .error("ERR Client sent AUTH, but no password is set. Did you mean AUTH <username> <password>?")
            }
            if pw == want {
                state.authenticated = true
                // Bind to the default ACL user so per-command rules
                // still apply (legacy clients land on the permissive
                // `default` profile by default).
                state.aclUser = acl?.user(named: "default")
                return .simpleString("OK")
            }
            return .error("WRONGPASS invalid username-password pair or user is disabled.")
        case 2:
            guard let user = command.textArg(0),
                  let pw = command.textArg(1) else {
                return .error("ERR wrong number of arguments for 'auth' command")
            }
            if let acl = acl, let u = acl.authenticate(name: user, password: pw) {
                state.authenticated = true
                state.aclUser = u
                return .simpleString("OK")
            }
            return .error("WRONGPASS invalid username-password pair or user is disabled.")
        default:
            return .error("ERR wrong number of arguments for 'auth' command")
        }
    }

    private func dispatchWHOAMI(state: ConnectionState) -> RESPValue {
        if let u = state.aclUser {
            return .bulkString(u.name)
        }
        // No ACL bound — Redis returns "default".
        return .bulkString("default")
    }

    private func dispatchACL(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        guard let acl = acl else {
            return .error("ERR ACL not configured")
        }
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'acl' command")
        }
        switch sub {
        case "WHOAMI":
            return dispatchWHOAMI(state: state)
        case "LIST":
            let names = acl.list().sorted()
            return .array(names.compactMap { name -> RESPValue? in
                guard let u = acl.user(named: name) else { return nil }
                return .bulkString(acl.format(u))
            })
        case "USERS":
            let names = acl.list().sorted()
            return .array(names.map(RESPValue.bulkString))
        case "GETUSER":
            guard let name = command.textArg(1) else {
                return .error("ERR wrong number of arguments for 'acl|getuser'")
            }
            guard let u = acl.user(named: name) else {
                return .array(Optional<[RESPValue]>.none)
            }
            // Mirrors Redis's nested key/value layout.
            var out: [RESPValue] = []
            out.append(.bulkString("flags"))
            var flags: [RESPValue] = []
            flags.append(.bulkString(u.enabled ? "on" : "off"))
            if u.nopass { flags.append(.bulkString("nopass")) }
            if u.allowAllCommands { flags.append(.bulkString("allcommands")) }
            if u.keyPatterns == ["*"] { flags.append(.bulkString("allkeys")) }
            out.append(.array(flags))
            out.append(.bulkString("passwords"))
            out.append(.array(u.passwordHashes.sorted().map(RESPValue.bulkString)))
            out.append(.bulkString("commands"))
            var commandRules: [String] = []
            if u.allowAllCommands {
                commandRules.append("+@all")
            } else {
                commandRules.append("-@all")
            }
            for c in u.allowedCommands.sorted() { commandRules.append("+\(c.lowercased())") }
            for c in u.deniedCommands.sorted() { commandRules.append("-\(c.lowercased())") }
            out.append(.bulkString(commandRules.joined(separator: " ")))
            out.append(.bulkString("keys"))
            out.append(.array(u.keyPatterns.map(RESPValue.bulkString)))
            return .array(out)
        case "SETUSER":
            guard let name = command.textArg(1) else {
                return .error("ERR wrong number of arguments for 'acl|setuser'")
            }
            let rules = command.args.dropFirst(2).compactMap { String(data: $0, encoding: .utf8) }
            do {
                _ = try acl.setUser(name: name, rules: Array(rules))
                return .simpleString("OK")
            } catch let e as KeyStoreError {
                return .error(String(describing: e))
            } catch {
                return .error("ERR \(error)")
            }
        case "DELUSER":
            let names = command.args.dropFirst().compactMap { String(data: $0, encoding: .utf8) }
            return .integer(Int64(acl.deleteUsers(Array(names))))
        case "CAT":
            // Redis returns category names. swiftka has a single-tier
            // ACL so we surface a static list — enough to keep clients
            // that probe for categories happy.
            let cats = [
                "keyspace", "read", "write", "set", "sortedset", "list",
                "hash", "string", "bitmap", "hyperloglog", "geo",
                "stream", "pubsub", "admin", "fast", "slow", "blocking",
                "dangerous", "connection", "transaction", "scripting",
            ]
            return .array(cats.map(RESPValue.bulkString))
        case "HELP":
            return .array([
                .bulkString("ACL SETUSER <name> [rule ...]"),
                .bulkString("ACL GETUSER <name>"),
                .bulkString("ACL DELUSER <name> [name ...]"),
                .bulkString("ACL LIST"),
                .bulkString("ACL USERS"),
                .bulkString("ACL WHOAMI"),
                .bulkString("ACL CAT"),
                .bulkString("ACL HELP"),
            ])
        default:
            return .error("ERR Unknown ACL subcommand or wrong number of arguments for '\(sub.lowercased())'")
        }
    }

    // MARK: - Phase 31 — scripting (EVAL/EVALSHA/SCRIPT/FUNCTION)

    /// Builds a `ScriptEngine` bound to `state` so `redis.call(...)`
    /// recurses through the same per-connection authorization gate.
    private func makeScriptEngine(state: ConnectionState) -> ScriptEngine {
        ScriptEngine { [weak self] inner in
            guard let self = self else { return .error("ERR script engine detached") }
            // Recurse through the public dispatch so ACL + transaction
            // semantics are honoured inside scripts.
            return self.dispatch(inner, state: state)
        }
    }

    private func dispatchEVAL(_ command: RESPCommand, state: ConnectionState, byHash: Bool) -> RESPValue {
        // EVAL script numkeys key [key ...] arg [arg ...]
        // EVALSHA sha1 numkeys key [key ...] arg [arg ...]
        guard let scripts = scripts else {
            return .error("ERR scripting not configured")
        }
        guard command.args.count >= 2 else {
            return .error("ERR wrong number of arguments for '\(command.name.lowercased())' command")
        }
        let resolved: String
        if byHash {
            guard let sha = command.textArg(0)?.lowercased(),
                  let src = scripts.source(for: sha) else {
                return .error("NOSCRIPT No matching script. Please use EVAL.")
            }
            resolved = src
        } else {
            guard let src = command.textArg(0) else {
                return .error("ERR wrong number of arguments")
            }
            // EVAL implicitly registers the script so EVALSHA works
            // for the same source later (matches Redis behaviour).
            _ = scripts.load(src)
            resolved = src
        }
        guard let numKeysRaw = command.textArg(1), let numKeys = Int(numKeysRaw), numKeys >= 0 else {
            return .error("ERR value is not an integer or out of range")
        }
        let rest = Array(command.args.dropFirst(2))
        guard rest.count >= numKeys else {
            return .error("ERR Number of keys can't be greater than number of args")
        }
        let keys = rest.prefix(numKeys).compactMap { String(data: $0, encoding: .utf8) }
        let argv = rest.dropFirst(numKeys).compactMap { String(data: $0, encoding: .utf8) }
        let engine = makeScriptEngine(state: state)
        return engine.evaluate(resolved, keys: keys, argv: Array(argv))
    }

    private func dispatchSCRIPT(_ command: RESPCommand, state: ConnectionState) -> RESPValue {
        _ = state
        guard let scripts = scripts else {
            return .error("ERR scripting not configured")
        }
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'script' command")
        }
        switch sub {
        case "LOAD":
            guard let src = command.textArg(1) else {
                return .error("ERR wrong number of arguments for 'script|load'")
            }
            return .bulkString(scripts.load(src))
        case "EXISTS":
            let shas = command.args.dropFirst().compactMap { String(data: $0, encoding: .utf8) }
            let flags = scripts.exists(Array(shas))
            return .array(flags.map { .integer(Int64($0)) })
        case "FLUSH":
            scripts.flush()
            return .simpleString("OK")
        case "HELP":
            return .array([
                .bulkString("SCRIPT LOAD <script>"),
                .bulkString("SCRIPT EXISTS <sha1> [sha1 ...]"),
                .bulkString("SCRIPT FLUSH"),
                .bulkString("SCRIPT HELP"),
            ])
        default:
            return .error("ERR Unknown SCRIPT subcommand or wrong number of arguments for '\(sub.lowercased())'")
        }
    }

    /// `FUNCTION` — Redis 7 server-side library surface. swiftka v0.13.0
    /// stubs the read-only subcommands so clients that probe for
    /// functions don't fall over. Mutating subcommands (LOAD/DELETE/
    /// RESTORE) return an explicit NOT_SUPPORTED error.
    private func dispatchFUNCTION(_ command: RESPCommand) -> RESPValue {
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'function' command")
        }
        switch sub {
        case "LIST":
            return .array(Optional<[RESPValue]>.some([]))
        case "DUMP":
            return .bulkString("")
        case "STATS":
            return .array([
                .bulkString("running_script"),
                .bulkString(nil),
                .bulkString("engines"),
                .array(Optional<[RESPValue]>.some([])),
            ])
        case "FLUSH":
            return .simpleString("OK")
        case "LOAD", "DELETE", "RESTORE":
            return .error("ERR FUNCTION \(sub) is not supported by swiftka v0.13.0")
        case "HELP":
            return .array([
                .bulkString("FUNCTION LIST"),
                .bulkString("FUNCTION DUMP"),
                .bulkString("FUNCTION STATS"),
                .bulkString("FUNCTION FLUSH"),
                .bulkString("FUNCTION HELP"),
            ])
        default:
            return .error("ERR Unknown FUNCTION subcommand '\(sub.lowercased())'")
        }
    }

    // MARK: - Phase 18 — introspection / compat stubs

    private func dispatchDBSIZE() -> RESPValue {
        guard let keys = keys else { return .integer(0) }
        do { return .integer(Int64(try keys.dbSize())) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchFLUSHDB() -> RESPValue {
        guard let keys = keys else { return .simpleString("OK") }
        do { try keys.flushdb(); return .simpleString("OK") }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchOBJECT(_ command: RESPCommand) -> RESPValue {
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'object' command")
        }
        switch sub {
        case "ENCODING":
            // Real Redis returns "embstr"/"raw"/"int"/"listpack"/... per
            // type + size heuristics. swiftka's storage is SQLite-backed
            // so the "encoding" is synthetic, but we apply the same
            // thresholds Redis uses so clients that branch on encoding
            // still take the right path.
            //   - string:  Int64-parseable → "int";
            //              else ≤ 44 bytes → "embstr"; else "raw".
            //   - list:    ≤ 128 entries → "listpack"; else "quicklist".
            //   - set:     ≤ 128 entries → "listpack"; else "hashtable".
            //   - hash:    ≤ 128 entries → "listpack"; else "hashtable".
            //   - zset:    ≤ 128 entries → "listpack"; else "skiplist".
            //   - stream:  always "stream" (Redis matches).
            guard let key = command.textArg(1) else {
                return .error("ERR wrong number of arguments for 'object|encoding'")
            }
            do {
                guard let meta = try keys?.objectMeta(key: key) else {
                    return .error("ERR no such key")
                }
                let encoding: String
                switch meta.type {
                case .string:
                    let value = try keys?.get(key: key) ?? Data()
                    if let s = String(data: value, encoding: .utf8), Int64(s) != nil {
                        encoding = "int"
                    } else if value.count <= 44 {
                        encoding = "embstr"
                    } else {
                        encoding = "raw"
                    }
                case .list:
                    let n = (try keys?.llen(key: key)) ?? 0
                    encoding = n <= 128 ? "listpack" : "quicklist"
                case .set:
                    let n = (try keys?.scard(key: key)) ?? 0
                    encoding = n <= 128 ? "listpack" : "hashtable"
                case .hash:
                    let n = (try keys?.hlen(key: key)) ?? 0
                    encoding = n <= 128 ? "listpack" : "hashtable"
                case .zset:
                    let n = (try keys?.zcard(key: key)) ?? 0
                    encoding = n <= 128 ? "listpack" : "skiplist"
                case .stream:
                    encoding = "stream"
                }
                return .bulkString(encoding)
            } catch { return .error("ERR \(error)") }
        case "REFCOUNT", "FREQ":
            // Stable sentinels — refcount=1 is what Redis returns for
            // everything not interned; freq is 0 unless maxmemory-policy
            // is LFU (which swiftka doesn't implement).
            guard let key = command.textArg(1) else {
                return .error("ERR wrong number of arguments")
            }
            do {
                guard try keys?.objectMeta(key: key) != nil else {
                    return .error("ERR no such key")
                }
                return sub == "REFCOUNT" ? .integer(1) : .integer(0)
            } catch { return .error("ERR \(error)") }
        case "IDLETIME":
            // Time since the key was last accessed. swiftka tracks
            // mtime (mutation time) not atime, so we use that.
            guard let key = command.textArg(1) else {
                return .error("ERR wrong number of arguments")
            }
            do {
                guard let meta = try keys?.objectMeta(key: key) else {
                    return .error("ERR no such key")
                }
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                let idleSeconds = max(0, (now - meta.mtimeMS) / 1000)
                return .integer(idleSeconds)
            } catch { return .error("ERR \(error)") }
        case "HELP":
            return .array([
                .bulkString("OBJECT ENCODING <key>"),
                .bulkString("OBJECT FREQ <key>"),
                .bulkString("OBJECT IDLETIME <key>"),
                .bulkString("OBJECT REFCOUNT <key>"),
                .bulkString("OBJECT HELP"),
            ])
        default:
            return .error("ERR Unknown subcommand or wrong number of arguments for '\(sub.lowercased())'")
        }
    }

    private func dispatchDEBUG(_ command: RESPCommand) -> RESPValue {
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR DEBUG requires a subcommand")
        }
        switch sub {
        case "SLEEP":
            // DEBUG SLEEP seconds — block the event loop for a fixed
            // duration. Useful for clients that probe for timeout
            // semantics; swiftka honors a small upper bound to keep
            // tests fast.
            if let raw = command.textArg(1), let s = Double(raw), s >= 0 {
                let capped = min(s, 5.0)
                Thread.sleep(forTimeInterval: capped)
            }
            return .simpleString("OK")
        case "SET-ACTIVE-EXPIRE", "JMAP", "RELOAD":
            // No-op subcommands clients sometimes call.
            return .simpleString("OK")
        case "OBJECT":
            // DEBUG OBJECT key — short, single-line summary.
            guard let key = command.textArg(1) else {
                return .error("ERR wrong number of arguments")
            }
            do {
                guard let meta = try keys?.objectMeta(key: key) else {
                    return .error("ERR no such key")
                }
                let summary = "Value at:0x0 refcount:1 encoding:raw serializedlength:0 lru:0 lru_seconds_idle:0 type:\(meta.type.wireName)"
                return .simpleString(summary)
            } catch { return .error("ERR \(error)") }
        default:
            // Be permissive — DEBUG is for diagnostics, returning OK
            // for unknown subcommands keeps clients from crashing.
            return .simpleString("OK")
        }
    }

    private func dispatchCLUSTER(_ command: RESPCommand) -> RESPValue {
        // swiftka is single-node — cluster commands return sensible
        // single-node answers so clients that probe for clustering
        // don't fall over.
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'cluster' command")
        }
        switch sub {
        case "INFO":
            let info = """
                cluster_enabled:0\r
                cluster_state:ok\r
                cluster_slots_assigned:0\r
                cluster_slots_ok:0\r
                cluster_known_nodes:1\r
                cluster_size:0\r
                """
            return .bulkString(info)
        case "NODES":
            return .bulkString("")
        case "MYID":
            return .bulkString("0000000000000000000000000000000000000000")
        case "COUNTKEYSINSLOT", "KEYSLOT":
            return .integer(0)
        case "SLOTS", "SHARDS":
            return .array(Optional<[RESPValue]>.some([]))
        default:
            return .simpleString("OK")
        }
    }

    private func dispatchINFO(_ command: RESPCommand) -> RESPValue {
        // INFO [section]. swiftka returns a single combined payload
        // regardless of which section was requested — most clients
        // accept this without complaint.
        _ = command
        let info = """
            # Server\r
            redis_version:7.4.0\r
            redis_mode:standalone\r
            swiftka_version:\(serverVersion)\r
            os:swift\r
            \r
            # Clients\r
            connected_clients:1\r
            \r
            # Persistence\r
            loading:0\r
            \r
            # Stats\r
            total_connections_received:1\r
            \r
            # Replication\r
            role:master\r
            connected_slaves:0\r
            \r
            # Keyspace\r
            db0:keys=\((try? keys?.dbSize()) ?? 0),expires=0,avg_ttl=0\r
            """
        return .bulkString(info)
    }

    private func dispatchTIME() -> RESPValue {
        let now = Date().timeIntervalSince1970
        let secs = Int64(now)
        let micros = Int64((now - Double(secs)) * 1_000_000)
        return .array([
            .bulkString(String(secs)),
            .bulkString(String(micros)),
        ])
    }

    private func dispatchCONFIG(_ command: RESPCommand) -> RESPValue {
        // CONFIG GET/SET/RESETSTAT/REWRITE. Most clients (libraries
        // like redis-py) only call CONFIG GET for capability probing.
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'config' command")
        }
        switch sub {
        case "GET":
            // Return an empty array for any parameter; this matches the
            // Redis wire shape (alternating key/value bulks) without
            // pretending to support specific tunables.
            return .array(Optional<[RESPValue]>.some([]))
        case "SET", "RESETSTAT", "REWRITE":
            return .simpleString("OK")
        default:
            return .error("ERR Unknown CONFIG subcommand or wrong number of arguments for '\(sub.lowercased())'")
        }
    }

    // MARK: - Phase 24 — SLOWLOG / MEMORY / LATENCY

    private func dispatchSLOWLOG(_ command: RESPCommand) -> RESPValue {
        // swiftka doesn't keep a slow-command log yet. Return well-
        // shaped empties so monitoring clients (redis-cli, Prometheus
        // exporters) don't trip.
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'slowlog' command")
        }
        switch sub {
        case "GET":
            return .array(Optional<[RESPValue]>.some([]))
        case "LEN":
            return .integer(0)
        case "RESET":
            return .simpleString("OK")
        case "HELP":
            return .array([
                .bulkString("SLOWLOG GET [count]"),
                .bulkString("SLOWLOG LEN"),
                .bulkString("SLOWLOG RESET"),
                .bulkString("SLOWLOG HELP"),
            ])
        default:
            return .error("ERR Unknown SLOWLOG subcommand or wrong number of arguments for '\(sub.lowercased())'")
        }
    }

    private func dispatchMEMORY(_ command: RESPCommand) -> RESPValue {
        // Real Redis exposes detailed allocator statistics. swiftka
        // doesn't track those, so we surface the shape callers expect
        // with safe zero/empty values.
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'memory' command")
        }
        switch sub {
        case "USAGE":
            // MEMORY USAGE key [SAMPLES n] — Redis returns an integer
            // byte estimate or nil for missing keys. swiftka returns
            // 0 for existing keys (we don't track per-key size) and
            // nil for missing.
            guard let keys = keys, let key = command.textArg(1) else {
                return .bulkString(nil)
            }
            do {
                if try keys.objectMeta(key: key) != nil {
                    return .integer(0)
                }
                return .bulkString(nil)
            } catch { return .error("ERR \(error)") }
        case "STATS":
            return .array(Optional<[RESPValue]>.some([]))
        case "DOCTOR":
            return .bulkString("Sam, I detected a few issues in this Redis instance memory implants:\n\n - No actual implants installed. Memory looks fine.\n")
        case "PURGE":
            return .simpleString("OK")
        case "MALLOC-STATS":
            return .bulkString("swiftka-allocator: malloc-stats unavailable\n")
        case "HELP":
            return .array([
                .bulkString("MEMORY USAGE <key>"),
                .bulkString("MEMORY STATS"),
                .bulkString("MEMORY DOCTOR"),
                .bulkString("MEMORY PURGE"),
                .bulkString("MEMORY MALLOC-STATS"),
                .bulkString("MEMORY HELP"),
            ])
        default:
            return .error("ERR Unknown MEMORY subcommand or wrong number of arguments for '\(sub.lowercased())'")
        }
    }

    private func dispatchLATENCY(_ command: RESPCommand) -> RESPValue {
        // swiftka doesn't sample latency events. Return empties.
        guard let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'latency' command")
        }
        switch sub {
        case "HISTORY", "LATEST", "DOCTOR", "GRAPH":
            return .array(Optional<[RESPValue]>.some([]))
        case "RESET":
            return .integer(0)
        case "HELP":
            return .array([
                .bulkString("LATENCY HISTORY <event>"),
                .bulkString("LATENCY LATEST"),
                .bulkString("LATENCY DOCTOR"),
                .bulkString("LATENCY RESET"),
                .bulkString("LATENCY GRAPH <event>"),
                .bulkString("LATENCY HELP"),
            ])
        default:
            return .error("ERR Unknown LATENCY subcommand or wrong number of arguments for '\(sub.lowercased())'")
        }
    }

    // MARK: - Phase 20 — Streams

    /// Renders a stream entry as the wire shape Redis uses for
    /// XRANGE/XREAD/XREVRANGE replies: `[id, [field, value, field, value, ...]]`.
    private static func encodeStreamEntry(_ e: KeyStore.StreamEntry) -> RESPValue {
        var flat: [RESPValue] = []
        flat.reserveCapacity(e.fields.count * 2)
        for (f, v) in e.fields {
            flat.append(.bulkString(f))
            flat.append(.bulkString(v))
        }
        return .array([.bulkString(e.id), .array(flat)])
    }

    private func dispatchXADD(_ command: RESPCommand) -> RESPValue {
        // XADD key [NOMKSTREAM] [MAXLEN [~|=] count | MINID [~|=] id]
        //          id field value [field value ...]
        guard let keys = keys, command.args.count >= 4,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments for 'xadd' command")
        }
        var i = 1
        var noMkStream = false
        var trim: KeyStore.StreamTrim?
        // Parse optional NOMKSTREAM / MAXLEN / MINID before the id.
        while i < command.args.count {
            let token = command.textArg(i)?.uppercased() ?? ""
            switch token {
            case "NOMKSTREAM":
                noMkStream = true
                i += 1
            case "MAXLEN":
                var j = i + 1
                if j < command.args.count,
                   let approx = command.textArg(j),
                   (approx == "~" || approx == "=") { j += 1 }
                guard j < command.args.count,
                      let n = command.textArg(j).flatMap(Int.init) else {
                    return .error("ERR syntax error")
                }
                trim = .maxLen(n)
                i = j + 1
            case "MINID":
                var j = i + 1
                if j < command.args.count,
                   let approx = command.textArg(j),
                   (approx == "~" || approx == "=") { j += 1 }
                guard j < command.args.count,
                      let raw = command.textArg(j),
                      let parsed = StreamIDParser.parse(raw, missingSeq: 0) else {
                    return .error("ERR Invalid stream ID specified as stream command argument")
                }
                trim = .minId(parsed.0, parsed.1)
                i = j + 1
            default:
                // Not an option — must be the id.
                break
            }
            if token != "NOMKSTREAM" && token != "MAXLEN" && token != "MINID" {
                break
            }
        }
        // Now `i` points at the id arg.
        guard i < command.args.count,
              let idArg = command.textArg(i) else {
            return .error("ERR wrong number of arguments for 'xadd' command")
        }
        let id: (Int64, Int64)?
        if idArg == "*" {
            id = nil
        } else {
            guard let parsed = StreamIDParser.parse(idArg, missingSeq: 0) else {
                return .error("ERR Invalid stream ID specified as stream command argument")
            }
            id = parsed
        }
        // Field/value pairs come after the id.
        let rest = command.args.dropFirst(i + 1)
        if rest.count < 2 || rest.count % 2 != 0 {
            return .error("ERR wrong number of arguments for XADD")
        }
        var pairs: [(String, Data)] = []
        var p = rest.startIndex
        while p < rest.endIndex {
            guard let field = String(data: rest[p], encoding: .utf8) else {
                return .error("ERR invalid field encoding")
            }
            pairs.append((field, rest[p + 1]))
            p = rest.index(p, offsetBy: 2)
        }
        do {
            if let chosen = try keys.xaddEx(key: key, id: id, fields: pairs,
                                            trim: trim, noMkStream: noMkStream) {
                return .bulkString("\(chosen.0)-\(chosen.1)")
            }
            // NOMKSTREAM + missing stream → nil bulk.
            return .bulkString(nil)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchXLEN(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        do { return .integer(Int64(try keys.xlen(key: key))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchXRANGE(_ command: RESPCommand, reverse: Bool) -> RESPValue {
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0),
              let startArg = command.textArg(1),
              let endArg   = command.textArg(2) else {
            return .error("ERR wrong number of arguments")
        }
        // XREVRANGE inverts the start/end semantics.
        let lowArg  = reverse ? endArg   : startArg
        let highArg = reverse ? startArg : endArg
        // For lower bound, bare ms means seq=0; for upper bound, seq=Int64.max.
        guard let lo = StreamIDParser.parse(lowArg,  missingSeq: 0, upperBoundForBareMS: false),
              let hi = StreamIDParser.parse(highArg, missingSeq: Int64.max, upperBoundForBareMS: true) else {
            return .error("ERR Invalid stream ID specified as stream command argument")
        }
        var count: Int?
        if command.args.count >= 5,
           command.textArg(3)?.uppercased() == "COUNT",
           let n = command.textArg(4).flatMap(Int.init) {
            count = n
        }
        do {
            let entries = try keys.xrange(key: key, start: lo, end: hi,
                                          count: count, reverse: reverse)
            return .array(entries.map { Self.encodeStreamEntry($0) })
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchXREAD(_ command: RESPCommand) -> RESPValue {
        // XREAD [COUNT n] [BLOCK ms] STREAMS key [key ...] id [id ...]
        guard let keys = keys, command.args.count >= 3 else {
            return .error("ERR wrong number of arguments for 'xread' command")
        }
        var count: Int?
        var streamsIdx: Int?
        var i = 0
        while i < command.args.count {
            let token = command.textArg(i)?.uppercased() ?? ""
            switch token {
            case "STREAMS":
                streamsIdx = i + 1
                i = command.args.count // break
            case "COUNT":
                if i + 1 < command.args.count,
                   let n = command.textArg(i + 1).flatMap(Int.init) {
                    count = n
                    i += 2
                } else { return .error("ERR syntax error") }
            case "BLOCK":
                // Honored but non-blocking — just consume the ms arg.
                if i + 1 < command.args.count { i += 2 } else { return .error("ERR syntax error") }
            default:
                return .error("ERR syntax error")
            }
        }
        guard let start = streamsIdx else {
            return .error("ERR syntax error in XREAD")
        }
        let remaining = command.args.count - start
        guard remaining > 0, remaining % 2 == 0 else {
            return .error("ERR Unbalanced 'xread' list of streams: for each stream key an ID or '$' must be specified.")
        }
        let halfway = remaining / 2
        var pairs: [(String, (Int64, Int64))] = []
        for k in 0..<halfway {
            guard let key = command.textArg(start + k),
                  let idArg = command.textArg(start + halfway + k) else {
                return .error("ERR syntax error")
            }
            // `$` means "everything after the current last id" -> ask
            // the storage for the current top before XREAD.
            let id: (Int64, Int64)
            if idArg == "$" {
                // Treat as "max so far"; xread expects "strictly greater
                // than this". We look up the last entry id under the
                // lock.
                let entries = (try? keys.xrange(key: key,
                                                start: StreamIDParser.minID,
                                                end: StreamIDParser.maxID,
                                                count: nil, reverse: true))?.first
                if let e = entries {
                    id = (e.ms, e.seq)
                } else {
                    id = (0, 0)
                }
            } else {
                guard let parsed = StreamIDParser.parse(idArg, missingSeq: 0) else {
                    return .error("ERR Invalid stream ID specified as stream command argument")
                }
                id = parsed
            }
            pairs.append((key, id))
        }
        do {
            let result = try keys.xread(streams: pairs, count: count)
            if result.isEmpty { return .array(nil) }
            var out: [RESPValue] = []
            for (key, entries) in result {
                out.append(.array([
                    .bulkString(key),
                    .array(entries.map { Self.encodeStreamEntry($0) }),
                ]))
            }
            return .array(out)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchXDEL(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0) else {
            return .error("ERR wrong number of arguments")
        }
        var ids: [(Int64, Int64)] = []
        for i in 1..<command.args.count {
            guard let arg = command.textArg(i),
                  let parsed = StreamIDParser.parse(arg, missingSeq: 0) else {
                return .error("ERR Invalid stream ID specified as stream command argument")
            }
            ids.append(parsed)
        }
        do { return .integer(Int64(try keys.xdel(key: key, ids: ids))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchXTRIM(_ command: RESPCommand) -> RESPValue {
        // XTRIM key MAXLEN [~|=] count
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0),
              let mode = command.textArg(1)?.uppercased(),
              mode == "MAXLEN" else {
            return .error("ERR syntax error")
        }
        // The ~ approximate marker is accepted but ignored.
        var nIdx = 2
        if let tilde = command.textArg(2), tilde == "~" || tilde == "=" { nIdx = 3 }
        guard nIdx < command.args.count,
              let n = command.textArg(nIdx).flatMap(Int.init) else {
            return .error("ERR syntax error")
        }
        do { return .integer(Int64(try keys.xtrim(key: key, maxLen: n))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    // MARK: - Phase 23 — Stream consumer groups

    private func dispatchXGROUP(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'xgroup' command")
        }
        switch sub {
        case "CREATE":
            // XGROUP CREATE key group id [MKSTREAM]
            guard command.args.count >= 4,
                  let key = command.textArg(1),
                  let groupName = command.textArg(2),
                  let idArg = command.textArg(3) else {
                return .error("ERR wrong number of arguments for 'xgroup|create'")
            }
            let mkstream = command.args.count >= 5 &&
                           command.textArg(4)?.uppercased() == "MKSTREAM"
            let id: (Int64, Int64)
            if idArg == "$" {
                id = (Int64.max, Int64.max)
            } else if let p = StreamIDParser.parse(idArg, missingSeq: 0) {
                id = p
            } else {
                return .error("ERR Invalid stream ID specified as stream command argument")
            }
            do {
                try keys.xgroupCreate(key: key, group: groupName, startId: id, mkstream: mkstream)
                return .simpleString("OK")
            } catch let e as KeyStoreError { return .error(String(describing: e)) }
            catch { return .error("ERR \(error)") }
        case "SETID":
            guard command.args.count >= 4,
                  let key = command.textArg(1),
                  let groupName = command.textArg(2),
                  let idArg = command.textArg(3) else {
                return .error("ERR wrong number of arguments")
            }
            let id: (Int64, Int64)
            if idArg == "$" {
                id = (Int64.max, Int64.max)
            } else if let p = StreamIDParser.parse(idArg, missingSeq: 0) {
                id = p
            } else {
                return .error("ERR Invalid stream ID specified as stream command argument")
            }
            do {
                try keys.xgroupSetId(key: key, group: groupName, id: id)
                return .simpleString("OK")
            } catch let e as KeyStoreError { return .error(String(describing: e)) }
            catch { return .error("ERR \(error)") }
        case "DESTROY":
            guard command.args.count >= 3,
                  let key = command.textArg(1),
                  let groupName = command.textArg(2) else {
                return .error("ERR wrong number of arguments")
            }
            do { return .integer(Int64(try keys.xgroupDestroy(key: key, group: groupName))) }
            catch let e as KeyStoreError { return .error(String(describing: e)) }
            catch { return .error("ERR \(error)") }
        case "CREATECONSUMER":
            // Consumers are implicit in swiftka — XREADGROUP creates
            // them on first use. Honor the call as a no-op success.
            return .integer(1)
        case "DELCONSUMER":
            guard command.args.count >= 4,
                  let key = command.textArg(1),
                  let groupName = command.textArg(2),
                  let consumer = command.textArg(3) else {
                return .error("ERR wrong number of arguments")
            }
            do { return .integer(Int64(try keys.xgroupDelConsumer(key: key, group: groupName, consumer: consumer))) }
            catch let e as KeyStoreError { return .error(String(describing: e)) }
            catch { return .error("ERR \(error)") }
        default:
            return .error("ERR Unknown XGROUP subcommand or wrong number of arguments for '\(sub.lowercased())'")
        }
    }

    private func dispatchXREADGROUP(_ command: RESPCommand) -> RESPValue {
        // XREADGROUP GROUP <g> <consumer> [COUNT n] [BLOCK ms] [NOACK] STREAMS key [key ...] id [id ...]
        guard let keys = keys, command.args.count >= 6,
              command.textArg(0)?.uppercased() == "GROUP",
              let groupName = command.textArg(1),
              let consumer = command.textArg(2) else {
            return .error("ERR wrong number of arguments for 'xreadgroup' command")
        }
        var count: Int?
        var streamsIdx: Int?
        var i = 3
        while i < command.args.count {
            let token = command.textArg(i)?.uppercased() ?? ""
            switch token {
            case "STREAMS":
                streamsIdx = i + 1
                i = command.args.count
            case "COUNT":
                if i + 1 < command.args.count,
                   let n = command.textArg(i + 1).flatMap(Int.init) { count = n; i += 2 }
                else { return .error("ERR syntax error") }
            case "BLOCK":
                if i + 1 < command.args.count { i += 2 } else { return .error("ERR syntax error") }
            case "NOACK":
                i += 1
            default:
                return .error("ERR syntax error")
            }
        }
        guard let start = streamsIdx else {
            return .error("ERR syntax error in XREADGROUP")
        }
        let remaining = command.args.count - start
        guard remaining > 0, remaining % 2 == 0 else {
            return .error("ERR Unbalanced 'xreadgroup' list of streams")
        }
        let halfway = remaining / 2
        var streams: [(String, String)] = []
        for k in 0..<halfway {
            guard let key = command.textArg(start + k),
                  let id = command.textArg(start + halfway + k) else {
                return .error("ERR syntax error")
            }
            streams.append((key, id))
        }
        do {
            let result = try keys.xreadGroup(group: groupName,
                                             consumer: consumer,
                                             streams: streams,
                                             count: count)
            if result.isEmpty { return .array(nil) }
            var out: [RESPValue] = []
            for (key, entries) in result {
                out.append(.array([
                    .bulkString(key),
                    .array(entries.map { Self.encodeStreamEntry($0) }),
                ]))
            }
            return .array(out)
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchXACK(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, command.args.count >= 3,
              let key = command.textArg(0),
              let groupName = command.textArg(1) else {
            return .error("ERR wrong number of arguments")
        }
        var ids: [(Int64, Int64)] = []
        for i in 2..<command.args.count {
            guard let arg = command.textArg(i),
                  let parsed = StreamIDParser.parse(arg, missingSeq: 0) else {
                return .error("ERR Invalid stream ID specified as stream command argument")
            }
            ids.append(parsed)
        }
        do { return .integer(Int64(try keys.xack(key: key, group: groupName, ids: ids))) }
        catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchXPENDING(_ command: RESPCommand) -> RESPValue {
        // XPENDING key group  (summary form — extended form is a v0.7 polish)
        guard let keys = keys, command.args.count >= 2,
              let key = command.textArg(0),
              let groupName = command.textArg(1) else {
            return .error("ERR wrong number of arguments for 'xpending' command")
        }
        do {
            let summary = try keys.xpendingSummary(key: key, group: groupName)
            // 4-element reply: [total, minId, maxId, [[consumer, count], ...]]
            let minId: RESPValue = summary.minId.map { .bulkString("\($0.0)-\($0.1)") } ?? .bulkString(nil)
            let maxId: RESPValue = summary.maxId.map { .bulkString("\($0.0)-\($0.1)") } ?? .bulkString(nil)
            let perConsumer: RESPValue = .array(summary.perConsumer.map { (name, count) in
                .array([.bulkString(name), .bulkString(String(count))])
            })
            return .array([.integer(Int64(summary.total)), minId, maxId, perConsumer])
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchXCLAIM(_ command: RESPCommand) -> RESPValue {
        // XCLAIM key group consumer min-idle-time id [id ...]
        guard let keys = keys, command.args.count >= 5,
              let key = command.textArg(0),
              let groupName = command.textArg(1),
              let consumer = command.textArg(2),
              let minIdle = command.textArg(3).flatMap(Int64.init) else {
            return .error("ERR wrong number of arguments for 'xclaim' command")
        }
        var ids: [(Int64, Int64)] = []
        for i in 4..<command.args.count {
            guard let arg = command.textArg(i),
                  let parsed = StreamIDParser.parse(arg, missingSeq: 0) else {
                return .error("ERR Invalid stream ID specified as stream command argument")
            }
            ids.append(parsed)
        }
        do {
            let entries = try keys.xclaim(key: key, group: groupName,
                                          newConsumer: consumer,
                                          minIdleMs: minIdle, ids: ids)
            return .array(entries.map { Self.encodeStreamEntry($0) })
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }

    private func dispatchXINFO(_ command: RESPCommand) -> RESPValue {
        guard let keys = keys, let sub = command.textArg(0)?.uppercased() else {
            return .error("ERR wrong number of arguments for 'xinfo' command")
        }
        switch sub {
        case "STREAM":
            guard let key = command.textArg(1) else { return .error("ERR wrong number of arguments") }
            do {
                guard let info = try keys.xinfoStream(key: key) else {
                    return .error("ERR no such key")
                }
                let first: RESPValue = info.firstId.map { .bulkString("\($0.0)-\($0.1)") } ?? .bulkString(nil)
                let last:  RESPValue = info.lastId.map  { .bulkString("\($0.0)-\($0.1)") } ?? .bulkString(nil)
                return .array([
                    .bulkString("length"),       .integer(Int64(info.length)),
                    .bulkString("first-entry"),  first,
                    .bulkString("last-entry"),   last,
                    .bulkString("groups"),       .integer(Int64(info.groupCount)),
                ])
            } catch let e as KeyStoreError { return .error(String(describing: e)) }
            catch { return .error("ERR \(error)") }
        case "GROUPS":
            guard let key = command.textArg(1) else { return .error("ERR wrong number of arguments") }
            do {
                let groups = try keys.xinfoGroups(key: key)
                return .array(groups.map { g in
                    .array([
                        .bulkString("name"),
                        .bulkString(g.name),
                        .bulkString("last-delivered-id"),
                        .bulkString("\(g.lastDeliveredMs)-\(g.lastDeliveredSeq)"),
                    ])
                })
            } catch let e as KeyStoreError { return .error(String(describing: e)) }
            catch { return .error("ERR \(error)") }
        case "HELP":
            return .array([
                .bulkString("XINFO STREAM <key>"),
                .bulkString("XINFO GROUPS <key>"),
                .bulkString("XINFO HELP"),
            ])
        default:
            return .error("ERR Unknown XINFO subcommand or wrong number of arguments for '\(sub.lowercased())'")
        }
    }

    private func dispatchXAUTOCLAIM(_ command: RESPCommand) -> RESPValue {
        // XAUTOCLAIM key group consumer min-idle-time start [COUNT count] [JUSTID]
        guard let keys = keys, command.args.count >= 5,
              let key = command.textArg(0),
              let groupName = command.textArg(1),
              let consumer = command.textArg(2),
              let minIdle = command.textArg(3).flatMap(Int64.init),
              let startArg = command.textArg(4) else {
            return .error("ERR wrong number of arguments for 'xautoclaim' command")
        }
        guard let start = StreamIDParser.parse(startArg, missingSeq: 0) else {
            return .error("ERR Invalid stream ID specified as stream command argument")
        }
        var count = 100
        var justId = false
        var i = 5
        while i < command.args.count {
            let token = command.textArg(i)?.uppercased()
            switch token {
            case "COUNT":
                guard i + 1 < command.args.count,
                      let n = command.textArg(i + 1).flatMap(Int.init) else {
                    return .error("ERR syntax error")
                }
                count = n; i += 2
            case "JUSTID":
                justId = true; i += 1
            default:
                return .error("ERR syntax error")
            }
        }
        do {
            let (next, claimed, deleted) = try keys.xautoclaim(
                key: key, group: groupName,
                newConsumer: consumer,
                minIdleMs: minIdle,
                start: start, count: count
            )
            // Reply shape: [next-cursor, [entries...], [deleted-ids...]]
            let entries: RESPValue
            if justId {
                entries = .array(claimed.map { .bulkString($0.id) })
            } else {
                entries = .array(claimed.map { Self.encodeStreamEntry($0) })
            }
            return .array([
                .bulkString(next),
                entries,
                .array(deleted.map { .bulkString($0) }),
            ])
        } catch let e as KeyStoreError { return .error(String(describing: e)) }
        catch { return .error("ERR \(error)") }
    }
}
