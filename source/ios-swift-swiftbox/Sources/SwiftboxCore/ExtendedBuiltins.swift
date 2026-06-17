import Foundation

/// A second batch of userland builtins: more of the coreutils/util-linux set
/// that Termux ships, implemented as pure-Swift interpreted commands so the
/// whole environment works *simulated* on any host — no device, no native
/// toolchain. Each one reads from a file operand or piped stdin and is testable
/// headlessly. Native (compiled) ports can replace any of these later for speed
/// without changing the command surface.
extension Shell {
    func registerExtendedUtils() {
        // MARK: text in/out helpers reused below
        func lines(of text: String) -> [String] {
            var l = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if l.last == "" { l.removeLast() }
            return l
        }

        // MARK: printf — a useful subset (%s %d %x %o %c %% and \n \t \\ escapes)
        register("printf") { args, _ in
            guard let format = args.first else {
                return CommandResult(stderr: "printf: usage: printf FORMAT [ARG...]\n", exitCode: 1)
            }
            let operands = Array(args.dropFirst())
            var out = ""
            var argi = 0
            let fmt = Array(format)
            var i = 0
            func nextArg() -> String { defer { argi += 1 }; return argi < operands.count ? operands[argi] : "" }
            while i < fmt.count {
                let c = fmt[i]
                if c == "\\", i + 1 < fmt.count {
                    i += 1
                    switch fmt[i] {
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "r": out += "\r"
                    case "\\": out += "\\"
                    default: out.append(fmt[i])
                    }
                } else if c == "%", i + 1 < fmt.count {
                    i += 1
                    switch fmt[i] {
                    case "%": out += "%"
                    case "s": out += nextArg()
                    case "d", "i": out += String(Int(nextArg()) ?? 0)
                    case "x": out += String(Int(nextArg()) ?? 0, radix: 16)
                    case "o": out += String(Int(nextArg()) ?? 0, radix: 8)
                    case "c": out += String(nextArg().first ?? " ")
                    default: out.append(fmt[i])
                    }
                } else {
                    out.append(c)
                }
                i += 1
            }
            return CommandResult(stdout: out)
        }

        // MARK: seq — seq LAST | seq FIRST LAST | seq FIRST STEP LAST
        register("seq") { args, _ in
            let nums = args.compactMap { Int($0) }
            var first = 1, step = 1, last = 0
            switch nums.count {
            case 1: last = nums[0]
            case 2: first = nums[0]; last = nums[1]
            case 3: first = nums[0]; step = nums[1]; last = nums[2]
            default: return CommandResult(stderr: "seq: usage: seq [FIRST [STEP]] LAST\n", exitCode: 1)
            }
            guard step != 0 else { return CommandResult(stderr: "seq: step cannot be zero\n", exitCode: 1) }
            var out = ""
            var v = first
            if step > 0 { while v <= last { out += "\(v)\n"; v += step } }
            else { while v >= last { out += "\(v)\n"; v += step } }
            return CommandResult(stdout: out)
        }

        // MARK: yes — repeat a string (bounded so the simulation can't run away)
        register("yes") { args, _ in
            let s = args.isEmpty ? "y" : args.joined(separator: " ")
            return CommandResult(stdout: String(repeating: s + "\n", count: 1000))
        }

        // MARK: tac — reverse line order
        register("tac") { args, shell in
            let (text, err) = shell.gatherInput(args.filter { !$0.hasPrefix("-") }, command: "tac")
            if let err { return err }
            let out = lines(of: text).reversed().joined(separator: "\n")
            return CommandResult(stdout: out.isEmpty ? "" : out + "\n")
        }

        // MARK: nl — number non-empty lines
        register("nl") { args, shell in
            let (text, err) = shell.gatherInput(args.filter { !$0.hasPrefix("-") }, command: "nl")
            if let err { return err }
            var out = ""
            var n = 1
            for line in lines(of: text) {
                if line.isEmpty { out += "\n" }
                else { out += String(format: "%6d\t%@\n", n, line); n += 1 }
            }
            return CommandResult(stdout: out)
        }

        // MARK: paste — merge corresponding lines with a delimiter (default tab)
        register("paste") { args, shell in
            var delim = "\t"
            var files: [String] = []
            var i = 0
            while i < args.count {
                if args[i] == "-d", i + 1 < args.count { delim = args[i + 1]; i += 2; continue }
                if !args[i].hasPrefix("-") { files.append(args[i]) }
                i += 1
            }
            var columns: [[String]] = []
            if files.isEmpty {
                guard let piped = shell.takePipedInput() else {
                    return CommandResult(stderr: "paste: no input\n", exitCode: 1)
                }
                columns = [lines(of: piped)]
            } else {
                for f in files {
                    guard let t = try? shell.vfs.readString(shell.resolve(f)) else {
                        return CommandResult(stderr: "paste: \(f): No such file\n", exitCode: 1)
                    }
                    columns.append(lines(of: t))
                }
            }
            let rows = columns.map(\.count).max() ?? 0
            var out = ""
            for r in 0..<rows {
                out += columns.map { r < $0.count ? $0[r] : "" }.joined(separator: delim) + "\n"
            }
            return CommandResult(stdout: out)
        }

        // MARK: fold — wrap lines to a width (default 80)
        register("fold") { args, shell in
            var width = 80
            var files: [String] = []
            var i = 0
            while i < args.count {
                if args[i] == "-w", i + 1 < args.count { width = Int(args[i + 1]) ?? width; i += 2; continue }
                if args[i].hasPrefix("-w") { width = Int(args[i].dropFirst(2)) ?? width }
                else if !args[i].hasPrefix("-") { files.append(args[i]) }
                i += 1
            }
            let (text, err) = shell.gatherInput(files, command: "fold")
            if let err { return err }
            var out = ""
            for line in lines(of: text) {
                if line.isEmpty { out += "\n"; continue }
                var chars = Array(line)
                while chars.count > width {
                    out += String(chars.prefix(width)) + "\n"
                    chars.removeFirst(width)
                }
                out += String(chars) + "\n"
            }
            return CommandResult(stdout: out)
        }

        // MARK: comm-lite — `comm -12 A B` prints lines common to both files
        register("comm") { args, shell in
            let files = args.filter { !$0.hasPrefix("-") }
            guard files.count == 2,
                  let a = try? shell.vfs.readString(shell.resolve(files[0])),
                  let b = try? shell.vfs.readString(shell.resolve(files[1])) else {
                return CommandResult(stderr: "comm: usage: comm -12 FILE1 FILE2\n", exitCode: 1)
            }
            let setB = Set(lines(of: b))
            let common = lines(of: a).filter { setB.contains($0) }
            let out = common.joined(separator: "\n")
            return CommandResult(stdout: out.isEmpty ? "" : out + "\n")
        }

        // MARK: base64 — encode (default) / decode (-d)
        register("base64") { args, shell in
            let decode = args.contains("-d") || args.contains("--decode")
            let files = args.filter { !$0.hasPrefix("-") }
            let (text, err) = shell.gatherInput(files, command: "base64")
            if let err { return err }
            if decode {
                let stripped = text.replacingOccurrences(of: "\n", with: "")
                guard let data = Data(base64Encoded: stripped) else {
                    return CommandResult(stderr: "base64: invalid input\n", exitCode: 1)
                }
                return CommandResult(stdout: String(decoding: data, as: UTF8.self))
            }
            return CommandResult(stdout: Data(text.utf8).base64EncodedString() + "\n")
        }

        // MARK: sha256sum — checksum files or stdin (built on the in-house SHA256)
        register("sha256sum") { args, shell in
            let files = args.filter { !$0.hasPrefix("-") }
            if files.isEmpty {
                guard let piped = shell.takePipedInput() else {
                    return CommandResult(stderr: "sha256sum: no input\n", exitCode: 1)
                }
                return CommandResult(stdout: "\(SHA256.hexDigest(piped))  -\n")
            }
            var out = ""
            for f in files {
                guard let t = try? shell.vfs.readString(shell.resolve(f)) else {
                    return CommandResult(stderr: "sha256sum: \(f): No such file\n", exitCode: 1)
                }
                out += "\(SHA256.hexDigest(t))  \(f)\n"
            }
            return CommandResult(stdout: out)
        }

        // MARK: cksum — a simple, deterministic checksum (length-mixed FNV-1a)
        register("cksum") { args, shell in
            let files = args.filter { !$0.hasPrefix("-") }
            func sum(_ s: String) -> UInt32 {
                var h: UInt32 = 2166136261
                for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
                return h
            }
            if files.isEmpty {
                guard let piped = shell.takePipedInput() else {
                    return CommandResult(stderr: "cksum: no input\n", exitCode: 1)
                }
                return CommandResult(stdout: "\(sum(piped)) \(piped.utf8.count)\n")
            }
            var out = ""
            for f in files {
                guard let t = try? shell.vfs.readString(shell.resolve(f)) else {
                    return CommandResult(stderr: "cksum: \(f): No such file\n", exitCode: 1)
                }
                out += "\(sum(t)) \(t.utf8.count) \(f)\n"
            }
            return CommandResult(stdout: out)
        }

        // MARK: system info utilities
        register("whoami") { _, _ in CommandResult(stdout: "swiftbox\n") }
        register("id") { _, _ in CommandResult(stdout: "uid=1000(swiftbox) gid=1000(swiftbox)\n") }
        register("hostname") { _, _ in CommandResult(stdout: "localhost\n") }
        register("arch") { _, _ in CommandResult(stdout: "arm64\n") }

        register("realpath") { args, shell in
            let targets = args.filter { !$0.hasPrefix("-") }
            guard !targets.isEmpty else { return CommandResult(stdout: shell.cwd + "\n") }
            return CommandResult(stdout: targets.map { shell.resolve($0) }.joined(separator: "\n") + "\n")
        }

        register("sleep") { _, _ in .success }   // no-op in the simulation

        // MARK: expr — integer arithmetic and a couple of relational ops
        register("expr") { args, _ in
            guard args.count == 3, let a = Int(args[0]), let b = Int(args[2]) else {
                // Single value or string length passthrough.
                if args.count == 1 { return CommandResult(stdout: args[0] + "\n") }
                return CommandResult(stderr: "expr: usage: expr A OP B\n", exitCode: 2)
            }
            let r: Int
            switch args[1] {
            case "+": r = a + b
            case "-": r = a - b
            case "*": r = a * b
            case "/": guard b != 0 else { return CommandResult(stderr: "expr: division by zero\n", exitCode: 2) }; r = a / b
            case "%": guard b != 0 else { return CommandResult(stderr: "expr: division by zero\n", exitCode: 2) }; r = a % b
            case "<": r = a < b ? 1 : 0
            case ">": r = a > b ? 1 : 0
            case "=": r = a == b ? 1 : 0
            default: return CommandResult(stderr: "expr: unknown operator '\(args[1])'\n", exitCode: 2)
            }
            return CommandResult(stdout: "\(r)\n", exitCode: r == 0 ? 1 : 0)
        }

        // MARK: test / [ — a practical subset (string, -z/-n, file checks, int cmp)
        let testImpl: Builtin = { rawArgs, shell in
            var args = rawArgs
            if args.last == "]" { args.removeLast() }   // `[ ... ]` form
            func ok(_ b: Bool) -> CommandResult { CommandResult(exitCode: b ? 0 : 1) }
            switch args.count {
            case 0: return ok(false)
            case 1: return ok(!args[0].isEmpty)
            case 2:
                switch args[0] {
                case "-z": return ok(args[1].isEmpty)
                case "-n": return ok(!args[1].isEmpty)
                case "-e", "-f": return ok(shell.vfs.isFile(shell.resolve(args[1])))
                case "-d": return ok(shell.vfs.isDirectory(shell.resolve(args[1])))
                case "!": return ok(args[1].isEmpty)
                default: return ok(false)
                }
            case 3:
                let l = args[0], op = args[1], r = args[2]
                switch op {
                case "=", "==": return ok(l == r)
                case "!=": return ok(l != r)
                case "-eq": return ok(Int(l) == Int(r))
                case "-ne": return ok(Int(l) != Int(r))
                case "-lt": return ok((Int(l) ?? 0) < (Int(r) ?? 0))
                case "-le": return ok((Int(l) ?? 0) <= (Int(r) ?? 0))
                case "-gt": return ok((Int(l) ?? 0) > (Int(r) ?? 0))
                case "-ge": return ok((Int(l) ?? 0) >= (Int(r) ?? 0))
                default: return ok(false)
                }
            default: return ok(false)
            }
        }
        register("test", testImpl)
        register("[", testImpl)
    }
}
