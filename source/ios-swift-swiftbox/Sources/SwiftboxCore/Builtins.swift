import Foundation

/// The default userland builtins. Kept in a dedicated extension so the
/// interpreter core (``Shell``) stays focused on parsing and dispatch.
extension Shell {
    func registerDefaults() {
        registerExtendedUtils()
        registerEditors()
        register("echo") { args, _ in
            var a = args
            var newline = true
            if a.first == "-n" { newline = false; a.removeFirst() }
            return CommandResult(stdout: a.joined(separator: " ") + (newline ? "\n" : ""))
        }

        register("pwd") { _, shell in
            CommandResult(stdout: shell.cwd + "\n")
        }

        register("cd") { args, shell in
            let target = args.first ?? (shell.environment["HOME"] ?? "/")
            do {
                try shell.setCwd(target)
                return .success
            } catch {
                return CommandResult(stderr: "cd: \(target): No such directory\n", exitCode: 1)
            }
        }

        register("ls") { args, shell in
            let operands = args.filter { !$0.hasPrefix("-") }
            let path = shell.resolve(operands.first ?? ".")
            if shell.vfs.isDirectory(path) {
                let entries = (try? shell.vfs.list(path)) ?? []
                return CommandResult(stdout: entries.isEmpty ? "" : entries.joined(separator: "\n") + "\n")
            } else if shell.vfs.exists(path) {
                return CommandResult(stdout: (operands.first ?? path) + "\n")
            }
            return CommandResult(
                stderr: "ls: \(operands.first ?? path): No such file or directory\n",
                exitCode: 1
            )
        }

        register("cat") { args, shell in
            let files = args.filter { !$0.hasPrefix("-") }
            if files.isEmpty, let piped = shell.takePipedInput() {
                return CommandResult(stdout: piped)
            }
            var out = ""
            for a in files {
                guard let text = try? shell.vfs.readString(shell.resolve(a)) else {
                    return CommandResult(stdout: out, stderr: "cat: \(a): No such file\n", exitCode: 1)
                }
                out += text
            }
            return CommandResult(stdout: out)
        }

        register("grep") { args, shell in
            // Flags: -i (ignore case), -v (invert), -n (line numbers), -c (count).
            var ignoreCase = false, invert = false, number = false, countOnly = false
            var operands: [String] = []
            for a in args {
                if a.hasPrefix("-") && a.count > 1 {
                    for f in a.dropFirst() {
                        switch f {
                        case "i": ignoreCase = true
                        case "v": invert = true
                        case "n": number = true
                        case "c": countOnly = true
                        default: break
                        }
                    }
                } else {
                    operands.append(a)
                }
            }
            guard let pattern = operands.first else {
                return CommandResult(stderr: "grep: usage: grep [-ivnc] PATTERN [file...]\n", exitCode: 2)
            }
            let files = Array(operands.dropFirst())
            let needle = ignoreCase ? pattern.lowercased() : pattern

            func matches(_ line: String) -> Bool {
                let hay = ignoreCase ? line.lowercased() : line
                return hay.contains(needle) != invert
            }

            var sources: [(label: String?, text: String)] = []
            if files.isEmpty {
                guard let piped = shell.takePipedInput() else {
                    return CommandResult(stderr: "grep: no input\n", exitCode: 2)
                }
                sources.append((nil, piped))
            } else {
                for f in files {
                    guard let text = try? shell.vfs.readString(shell.resolve(f)) else {
                        return CommandResult(stderr: "grep: \(f): No such file\n", exitCode: 2)
                    }
                    sources.append((files.count > 1 ? f : nil, text))
                }
            }

            var out = ""
            var total = 0
            for source in sources {
                let lines = source.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let trimmed = (lines.last == "" ) ? Array(lines.dropLast()) : lines
                for (idx, line) in trimmed.enumerated() where matches(line) {
                    total += 1
                    if countOnly { continue }
                    var rendered = line
                    if number { rendered = "\(idx + 1):" + rendered }
                    if let label = source.label { rendered = "\(label):" + rendered }
                    out += rendered + "\n"
                }
            }
            if countOnly { out = "\(total)\n" }
            return CommandResult(stdout: out, exitCode: total > 0 ? 0 : 1)
        }

        register("head") { args, shell in
            shell.headTail(args, fromStart: true)
        }

        register("tail") { args, shell in
            shell.headTail(args, fromStart: false)
        }

        register("wc") { args, shell in
            var wantLines = false, wantWords = false, wantBytes = false
            var files: [String] = []
            for a in args {
                if a.hasPrefix("-") && a.count > 1 {
                    for f in a.dropFirst() {
                        switch f {
                        case "l": wantLines = true
                        case "w": wantWords = true
                        case "c": wantBytes = true
                        default: break
                        }
                    }
                } else {
                    files.append(a)
                }
            }
            if !wantLines && !wantWords && !wantBytes {
                wantLines = true; wantWords = true; wantBytes = true
            }
            func count(_ text: String) -> (l: Int, w: Int, c: Int) {
                let lines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
                let words = text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
                return (lines, words, text.utf8.count)
            }
            func render(_ t: (l: Int, w: Int, c: Int), _ label: String?) -> String {
                var parts: [String] = []
                if wantLines { parts.append(String(t.l)) }
                if wantWords { parts.append(String(t.w)) }
                if wantBytes { parts.append(String(t.c)) }
                if let label { parts.append(label) }
                return parts.joined(separator: " ") + "\n"
            }
            if files.isEmpty {
                guard let piped = shell.takePipedInput() else {
                    return CommandResult(stderr: "wc: no input\n", exitCode: 1)
                }
                return CommandResult(stdout: render(count(piped), nil))
            }
            var out = ""
            for f in files {
                guard let text = try? shell.vfs.readString(shell.resolve(f)) else {
                    return CommandResult(stderr: "wc: \(f): No such file\n", exitCode: 1)
                }
                out += render(count(text), f)
            }
            return CommandResult(stdout: out)
        }

        register("sort") { args, shell in
            var reverse = false, unique = false, numeric = false
            var files: [String] = []
            for a in args {
                if a.hasPrefix("-") && a.count > 1 {
                    for f in a.dropFirst() {
                        switch f {
                        case "r": reverse = true
                        case "u": unique = true
                        case "n": numeric = true
                        default: break
                        }
                    }
                } else {
                    files.append(a)
                }
            }
            var text = ""
            if files.isEmpty {
                guard let piped = shell.takePipedInput() else {
                    return CommandResult(stderr: "sort: no input\n", exitCode: 1)
                }
                text = piped
            } else {
                for f in files {
                    guard let t = try? shell.vfs.readString(shell.resolve(f)) else {
                        return CommandResult(stderr: "sort: \(f): No such file\n", exitCode: 1)
                    }
                    text += t
                }
            }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            if numeric {
                lines.sort { (Int($0) ?? 0) < (Int($1) ?? 0) }
            } else {
                lines.sort()
            }
            if reverse { lines.reverse() }
            if unique {
                var seen = Set<String>()
                lines = lines.filter { seen.insert($0).inserted }
            }
            let out = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            return CommandResult(stdout: out)
        }

        register("find") { args, shell in
            // Supports: find [path] [-name PATTERN] [-type f|d]
            var start = "."
            var namePattern: String?
            var typeFilter: Character?
            var i = 0
            while i < args.count {
                let a = args[i]
                if a == "-name", i + 1 < args.count {
                    namePattern = args[i + 1]; i += 2; continue
                }
                if a == "-type", i + 1 < args.count {
                    typeFilter = args[i + 1].first; i += 2; continue
                }
                if !a.hasPrefix("-") { start = a }
                i += 1
            }
            let base = shell.resolve(start)
            guard shell.vfs.isDirectory(base) else {
                if shell.vfs.exists(base) { return CommandResult(stdout: start + "\n") }
                return CommandResult(stderr: "find: '\(start)': No such file or directory\n", exitCode: 1)
            }
            func matches(_ entry: VirtualFileSystem.Entry) -> Bool {
                if let t = typeFilter {
                    if t == "d" && !entry.isDirectory { return false }
                    if t == "f" && entry.isDirectory { return false }
                }
                if let pattern = namePattern {
                    let name = (entry.path as NSString).lastPathComponent
                    if !Shell.globMatch(pattern, name) { return false }
                }
                return true
            }
            var out = ""
            // Include the start dir itself (mirrors `find`), unless filtered to files.
            if namePattern == nil, typeFilter != "f" { out += start + "\n" }
            for entry in (try? shell.vfs.walk(base)) ?? [] where matches(entry) {
                // Render relative to the start argument for readability.
                let rel = entry.path.hasPrefix(base)
                    ? start + String(entry.path.dropFirst(base.count))
                    : entry.path
                out += rel + "\n"
            }
            return CommandResult(stdout: out)
        }

        register("cp") { args, shell in
            let operands = args.filter { !$0.hasPrefix("-") }
            guard operands.count >= 2 else {
                return CommandResult(stderr: "cp: usage: cp SOURCE DEST\n", exitCode: 1)
            }
            let src = shell.resolve(operands[0])
            var dst = shell.resolve(operands[1])
            guard let data = try? shell.vfs.readFile(src) else {
                return CommandResult(stderr: "cp: \(operands[0]): No such file\n", exitCode: 1)
            }
            // If dest is an existing directory, copy into it with the same name.
            if shell.vfs.isDirectory(dst) {
                let name = (src as NSString).lastPathComponent
                dst = dst == "/" ? "/" + name : dst + "/" + name
            }
            do {
                try shell.vfs.writeFile(dst, data: data)
                return .success
            } catch {
                return CommandResult(stderr: "cp: cannot create '\(operands[1])'\n", exitCode: 1)
            }
        }

        register("mv") { args, shell in
            let operands = args.filter { !$0.hasPrefix("-") }
            guard operands.count >= 2 else {
                return CommandResult(stderr: "mv: usage: mv SOURCE DEST\n", exitCode: 1)
            }
            let src = shell.resolve(operands[0])
            var dst = shell.resolve(operands[1])
            guard let data = try? shell.vfs.readFile(src) else {
                return CommandResult(stderr: "mv: \(operands[0]): No such file\n", exitCode: 1)
            }
            if shell.vfs.isDirectory(dst) {
                let name = (src as NSString).lastPathComponent
                dst = dst == "/" ? "/" + name : dst + "/" + name
            }
            do {
                try shell.vfs.writeFile(dst, data: data)
                try shell.vfs.remove(src)
                return .success
            } catch {
                return CommandResult(stderr: "mv: cannot move '\(operands[0])'\n", exitCode: 1)
            }
        }

        register("ln") { args, shell in
            // Only symbolic links are supported (no hard links in the VFS).
            var symbolic = false
            var operands: [String] = []
            for a in args {
                if a.hasPrefix("-") {
                    if a.contains("s") { symbolic = true }
                } else {
                    operands.append(a)
                }
            }
            guard symbolic else {
                return CommandResult(stderr: "ln: only 'ln -s TARGET LINK' is supported\n", exitCode: 1)
            }
            guard operands.count >= 2 else {
                return CommandResult(stderr: "ln: usage: ln -s TARGET LINK\n", exitCode: 1)
            }
            let target = operands[0]
            var linkPath = shell.resolve(operands[1])
            // If LINK is an existing directory, create the link inside it.
            if shell.vfs.isDirectory(linkPath) {
                let name = (target as NSString).lastPathComponent
                linkPath = linkPath == "/" ? "/" + name : linkPath + "/" + name
            }
            do {
                try shell.vfs.createSymlink(linkPath, target: target)
                return .success
            } catch {
                return CommandResult(stderr: "ln: cannot create link '\(operands[1])'\n", exitCode: 1)
            }
        }

        register("readlink") { args, shell in
            guard let path = args.first(where: { !$0.hasPrefix("-") }) else {
                return CommandResult(stderr: "readlink: usage: readlink PATH\n", exitCode: 1)
            }
            do {
                let target = try shell.vfs.readlink(shell.resolve(path))
                return CommandResult(stdout: target + "\n")
            } catch {
                return CommandResult(stderr: "readlink: \(path): not a symbolic link\n", exitCode: 1)
            }
        }

        register("uniq") { args, shell in
            var countMode = false
            var files: [String] = []
            for a in args {
                if a == "-c" { countMode = true } else if !a.hasPrefix("-") { files.append(a) }
            }
            let (text, err) = shell.gatherInput(files, command: "uniq")
            if let err { return err }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            var out = ""
            var prev: String?
            var run = 0
            func flush() {
                guard let p = prev else { return }
                out += countMode ? "\(run) \(p)\n" : "\(p)\n"
            }
            for line in lines {
                if line == prev { run += 1 } else { flush(); prev = line; run = 1 }
            }
            flush()
            return CommandResult(stdout: out)
        }

        register("rev") { args, shell in
            let (text, err) = shell.gatherInput(args.filter { !$0.hasPrefix("-") }, command: "rev")
            if let err { return err }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            let out = lines.map { String($0.reversed()) }.joined(separator: "\n")
            return CommandResult(stdout: out.isEmpty ? "" : out + "\n")
        }

        register("basename") { args, _ in
            guard var name = args.first else {
                return CommandResult(stderr: "basename: usage: basename PATH [SUFFIX]\n", exitCode: 1)
            }
            name = (name as NSString).lastPathComponent
            if args.count > 1, name.hasSuffix(args[1]), name != args[1] {
                name = String(name.dropLast(args[1].count))
            }
            return CommandResult(stdout: name + "\n")
        }

        register("dirname") { args, _ in
            guard let path = args.first else {
                return CommandResult(stderr: "dirname: usage: dirname PATH\n", exitCode: 1)
            }
            let dir = (path as NSString).deletingLastPathComponent
            return CommandResult(stdout: (dir.isEmpty ? "." : dir) + "\n")
        }

        register("tee") { args, shell in
            var append = false
            var files: [String] = []
            for a in args {
                if a == "-a" { append = true } else if !a.hasPrefix("-") { files.append(a) }
            }
            let input = shell.takePipedInput() ?? ""
            for f in files {
                let path = shell.resolve(f)
                if append, let existing = try? shell.vfs.readString(path) {
                    try? shell.vfs.writeFile(path, string: existing + input)
                } else {
                    try? shell.vfs.writeFile(path, string: input)
                }
            }
            return CommandResult(stdout: input)
        }

        register("cut") { args, shell in
            // Supports: cut -d DELIM -f LIST   and   cut -c LIST  (1-based).
            var delim = "\t"
            var fieldSpec: String?
            var charSpec: String?
            var files: [String] = []
            var i = 0
            while i < args.count {
                let a = args[i]
                if a == "-d", i + 1 < args.count { delim = args[i + 1]; i += 2; continue }
                if a.hasPrefix("-d") { delim = String(a.dropFirst(2)); i += 1; continue }
                if a == "-f", i + 1 < args.count { fieldSpec = args[i + 1]; i += 2; continue }
                if a.hasPrefix("-f") { fieldSpec = String(a.dropFirst(2)); i += 1; continue }
                if a == "-c", i + 1 < args.count { charSpec = args[i + 1]; i += 2; continue }
                if a.hasPrefix("-c") { charSpec = String(a.dropFirst(2)); i += 1; continue }
                if !a.hasPrefix("-") { files.append(a) }
                i += 1
            }
            let (text, err) = shell.gatherInput(files, command: "cut")
            if let err { return err }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }

            func indices(_ spec: String) -> [Int] {
                spec.split(separator: ",").compactMap { Int($0) }.map { $0 - 1 }.filter { $0 >= 0 }
            }

            var out = ""
            if let fieldSpec {
                let idxs = indices(fieldSpec)
                for line in lines {
                    let parts = line.components(separatedBy: delim)
                    let picked = idxs.compactMap { $0 < parts.count ? parts[$0] : nil }
                    out += picked.joined(separator: delim) + "\n"
                }
            } else if let charSpec {
                let idxs = indices(charSpec)
                for line in lines {
                    let chars = Array(line)
                    let picked = idxs.compactMap { $0 < chars.count ? String(chars[$0]) : nil }
                    out += picked.joined() + "\n"
                }
            } else {
                return CommandResult(stderr: "cut: usage: cut -f LIST [-d DELIM] | cut -c LIST\n", exitCode: 1)
            }
            return CommandResult(stdout: out)
        }

        register("tr") { args, shell in
            // Supports: tr SET1 SET2 (translate) and tr -d SET1 (delete).
            var deleteMode = false
            var sets: [String] = []
            for a in args {
                if a == "-d" { deleteMode = true } else { sets.append(a) }
            }
            let input = shell.takePipedInput() ?? ""
            guard let set1 = sets.first else {
                return CommandResult(stderr: "tr: usage: tr SET1 SET2 | tr -d SET1\n", exitCode: 1)
            }
            let from = Array(Shell.expandTrSet(set1))
            if deleteMode {
                let drop = Set(from)
                return CommandResult(stdout: String(input.filter { !drop.contains($0) }))
            }
            guard sets.count > 1 else {
                return CommandResult(stderr: "tr: missing SET2\n", exitCode: 1)
            }
            let to = Array(Shell.expandTrSet(sets[1]))
            var map: [Character: Character] = [:]
            for (i, c) in from.enumerated() {
                map[c] = i < to.count ? to[i] : to.last
            }
            return CommandResult(stdout: String(input.map { map[$0] ?? $0 }))
        }

        register("sed") { args, shell in
            // Supports a single substitution: sed 's/PATTERN/REPLACEMENT/[g]'.
            let scripts = args.filter { !$0.hasPrefix("-") }
            guard let script = scripts.first, script.hasPrefix("s") else {
                return CommandResult(stderr: "sed: only 's/PATTERN/REPLACEMENT/[g]' is supported\n", exitCode: 1)
            }
            let files = Array(scripts.dropFirst())
            guard let parsed = Shell.parseSedSubstitution(script) else {
                return CommandResult(stderr: "sed: bad substitution '\(script)'\n", exitCode: 1)
            }
            let (text, err) = shell.gatherInput(files, command: "sed")
            if let err { return err }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let trailing = lines.last == ""
            if trailing { lines.removeLast() }
            let edited = lines.map { line -> String in
                if parsed.pattern.isEmpty { return line }
                if parsed.global {
                    return line.replacingOccurrences(of: parsed.pattern, with: parsed.replacement)
                }
                if let range = line.range(of: parsed.pattern) {
                    return line.replacingCharacters(in: range, with: parsed.replacement)
                }
                return line
            }
            let out = edited.joined(separator: "\n")
            return CommandResult(stdout: edited.isEmpty ? "" : out + "\n")
        }

        register("mkdir") { args, shell in
            let dirs = args.filter { !$0.hasPrefix("-") }
            for d in dirs {
                do {
                    try shell.vfs.makeDirectory(shell.resolve(d))
                } catch {
                    return CommandResult(stderr: "mkdir: cannot create directory '\(d)'\n", exitCode: 1)
                }
            }
            return .success
        }

        register("touch") { args, shell in
            for f in args {
                let p = shell.resolve(f)
                if !shell.vfs.exists(p) {
                    try? shell.vfs.writeFile(p, data: Data())
                }
            }
            return .success
        }

        register("rm") { args, shell in
            var recursive = false
            var targets: [String] = []
            for a in args {
                if a.hasPrefix("-") {
                    if a.contains("r") || a.contains("R") { recursive = true }
                } else {
                    targets.append(a)
                }
            }
            for f in targets {
                do {
                    try shell.vfs.remove(shell.resolve(f), recursive: recursive)
                } catch {
                    return CommandResult(stderr: "rm: cannot remove '\(f)'\n", exitCode: 1)
                }
            }
            return .success
        }

        // swiftbox helper: author a file without a full text editor.
        register("write") { args, shell in
            guard let file = args.first else {
                return CommandResult(stderr: "write: usage: write <file> <text...>\n", exitCode: 1)
            }
            let text = args.dropFirst().joined(separator: " ")
            do {
                try shell.vfs.writeFile(shell.resolve(file), string: text + "\n")
                return .success
            } catch {
                return CommandResult(stderr: "write: cannot write '\(file)'\n", exitCode: 1)
            }
        }

        register("env") { _, shell in
            let lines = shell.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            return CommandResult(stdout: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
        }

        register("export") { args, shell in
            for a in args { _ = shell.tryAssignment(a) }
            return .success
        }

        register("which") { args, shell in
            guard let name = args.first else { return CommandResult(exitCode: 1) }
            if shell.hasBuiltin(name) {
                return CommandResult(stdout: "\(name): swiftbox builtin\n")
            }
            return CommandResult(stderr: "which: no \(name) in (builtins)\n", exitCode: 1)
        }

        register("uname") { args, _ in
            if args.contains("-a") {
                return CommandResult(
                    stdout: "swiftbox \(SwiftboxEnvironment.version) ios-sandbox arm64 SwiftboxCore\n"
                )
            }
            return CommandResult(stdout: "swiftbox\n")
        }

        register("clear") { _, _ in
            CommandResult(stdout: "\u{1b}[2J\u{1b}[H")
        }

        register("true") { _, _ in .success }
        register("false") { _, _ in CommandResult(exitCode: 1) }

        // Run a script file from the VFS line by line through the interpreter.
        register("sh") { args, shell in
            let files = args.filter { !$0.hasPrefix("-") }
            guard let file = files.first else {
                return CommandResult(stderr: "sh: usage: sh SCRIPT\n", exitCode: 2)
            }
            guard let text = try? shell.vfs.readString(shell.resolve(file)) else {
                return CommandResult(stderr: "sh: \(file): No such file\n", exitCode: 1)
            }
            return shell.runSource(text)
        }

        // Execute a script in the current shell (like POSIX `.` / `source`):
        // assignments and `cd` persist after it returns.
        let sourceImpl: Builtin = { args, shell in
            guard let file = args.first else {
                return CommandResult(stderr: "source: usage: source FILE\n", exitCode: 2)
            }
            guard let text = try? shell.vfs.readString(shell.resolve(file)) else {
                return CommandResult(stderr: "source: \(file): No such file\n", exitCode: 1)
            }
            return shell.runSource(text)
        }
        register("source", sourceImpl)
        register(".", sourceImpl)

        register("pkg") { args, shell in
            shell.runPkg(args)
        }

        register("help") { _, shell in
            CommandResult(stdout: "swiftbox builtins: \(shell.builtinNames().joined(separator: " "))\n")
        }

        register("history") { args, shell in
            let limit = args.first.flatMap { Int($0) } ?? 0
            let entries = limit > 0 ? Array(shell.commandHistory.suffix(limit)) : shell.commandHistory
            let start = shell.commandHistory.count - entries.count
            var out = ""
            for (i, entry) in entries.enumerated() {
                out += "\(start + i + 1)  \(entry)\n"
            }
            return CommandResult(stdout: out)
        }
    }

    // MARK: pkg

    func runPkg(_ args: [String]) -> CommandResult {
        guard let sub = args.first else {
            return CommandResult(
                stderr: "pkg: usage: pkg <list|list-installed|install|remove|show|search|catalog|backlog|build|fetch|update|upgrade> ...\n",
                exitCode: 1
            )
        }
        let rest = Array(args.dropFirst())

        switch sub {
        case "list", "list-all":
            let lines = repository.available.values
                .sorted { $0.name < $1.name }
                .map { m in
                    "\(m.name)/\(m.version)\(repository.installed.contains(m.name) ? " [installed]" : "")"
                }
            return CommandResult(stdout: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")

        case "list-installed":
            let lines = repository.installed.sorted()
            return CommandResult(stdout: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")

        case "install", "add":
            do {
                let order = try repository.install(rest)
                return CommandResult(stdout: "Installing: \(order.joined(separator: " "))\n")
            } catch let error as PackageError {
                return CommandResult(stderr: "pkg: \(describe(error))\n", exitCode: 1)
            } catch {
                return CommandResult(stderr: "pkg: unexpected error\n", exitCode: 1)
            }

        case "remove", "uninstall":
            for name in rest {
                do {
                    try repository.remove(name)
                } catch let error as PackageError {
                    return CommandResult(stderr: "pkg: \(describe(error))\n", exitCode: 1)
                } catch {
                    return CommandResult(stderr: "pkg: unexpected error\n", exitCode: 1)
                }
            }
            return CommandResult(stdout: "Removed: \(rest.joined(separator: " "))\n")

        case "show", "info":
            guard let name = rest.first, let m = repository.manifest(for: name) else {
                return CommandResult(stderr: "pkg: no such package\n", exitCode: 1)
            }
            var out = "Package: \(m.name)\nVersion: \(m.version)\nArch: \(m.arch)\n"
            if !m.summary.isEmpty { out += "Summary: \(m.summary)\n" }
            if !m.dependencies.isEmpty { out += "Depends: \(m.dependencies.joined(separator: ", "))\n" }
            return CommandResult(stdout: out)

        case "search":
            let q = rest.first ?? ""
            let lines = repository.available.values
                .filter { $0.name.contains(q) || $0.summary.contains(q) }
                .sorted { $0.name < $1.name }
                .map { "\($0.name)/\($0.version) - \($0.summary)" }
            return CommandResult(stdout: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")

        case "catalog":
            guard let catalog = catalog else {
                return CommandResult(stderr: "pkg: no catalog available\n", exitCode: 1)
            }
            let lines = catalog.names.compactMap { name -> String? in
                guard let r = catalog.recipe(for: name) else { return nil }
                let mark = repository.installed.contains(name) ? " [installed]" : ""
                return "\(r.name)/\(r.metadata.rawVersion) (\(r.kind.rawValue), \(r.origin))\(mark)"
            }
            return CommandResult(stdout: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")

        case "backlog":
            guard let catalog = catalog else {
                return CommandResult(stderr: "pkg: no catalog available\n", exitCode: 1)
            }
            let backlog = catalog.portingBacklog()
            if backlog.isEmpty { return CommandResult(stdout: "porting backlog is empty\n") }
            var out = ""
            for kind in backlog.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let pkgs = backlog[kind] ?? []
                out += "\(kind.rawValue) (\(pkgs.count)): \(pkgs.joined(separator: " "))\n"
            }
            return CommandResult(stdout: out)

        case "build":
            guard let builder = builder else {
                return CommandResult(stderr: "pkg: no builder available\n", exitCode: 1)
            }
            guard !rest.isEmpty else {
                return CommandResult(stderr: "pkg: usage: pkg build <package>...\n", exitCode: 1)
            }
            do {
                let reports = try builder.build(rest)
                var out = ""
                var anyFailed = false
                for r in reports {
                    switch r.status {
                    case .built(let artifacts):
                        out += "built \(r.package) [\(r.target.rawValue)] -> \(artifacts.joined(separator: " "))\n"
                    case .deferred(let reason):
                        out += "deferred \(r.package): \(reason)\n"
                    case .failed(let reason):
                        out += "FAILED \(r.package): \(reason)\n"
                        anyFailed = true
                    }
                }
                return CommandResult(stdout: out, exitCode: anyFailed ? 1 : 0)
            } catch PackageBuilder.BuildError.notInCatalog(let n) {
                return CommandResult(stderr: "pkg: \(n) is not in the catalog\n", exitCode: 1)
            } catch let error as PackageError {
                return CommandResult(stderr: "pkg: \(describe(error))\n", exitCode: 1)
            } catch {
                return CommandResult(stderr: "pkg: build failed\n", exitCode: 1)
            }

        case "fetch":
            guard let fetcher = sourceFetcher else {
                return CommandResult(stderr: "pkg: no source fetcher configured\n", exitCode: 1)
            }
            guard let catalog = catalog else {
                return CommandResult(stderr: "pkg: no catalog available\n", exitCode: 1)
            }
            guard let name = rest.first, let recipe = catalog.recipe(for: name) else {
                return CommandResult(stderr: "pkg: \(rest.first ?? "?") is not in the catalog\n", exitCode: 1)
            }
            do {
                let result = try fetcher.fetch(recipe)
                let origin = result.fromCache ? "cache" : "source"
                return CommandResult(stdout: "Fetched \(result.package) from \(origin): \(result.byteCount) bytes, sha256 \(result.sha256.prefix(12))…\n")
            } catch let SourceError.checksumMismatch(_, expected, actual) {
                return CommandResult(stderr: "pkg: checksum mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)\n", exitCode: 1)
            } catch SourceError.unavailable {
                return CommandResult(stderr: "pkg: \(name): source unavailable offline (network URL)\n", exitCode: 1)
            } catch {
                return CommandResult(stderr: "pkg: fetch failed\n", exitCode: 1)
            }

        case "update":
            // `pkg update <url>` pulls a signed index from a remote host;
            // `pkg update` (no arg) rebuilds the index from the local store.
            if let url = rest.first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") }) {
                guard let client = remoteIndexClient else {
                    return CommandResult(stderr: "pkg: remote index fetching not enabled (network off)\n", exitCode: 1)
                }
                do {
                    let index = try client.fetch(url)
                    packageIndex = index
                    // Make remote entries resolvable as available packages.
                    for entry in index.entries where repository.manifest(for: entry.name) == nil {
                        repository.publish(PackageManifest(name: entry.name, version: entry.version))
                    }
                    return CommandResult(stdout: "Fetched remote index: \(index.entries.count) packages, signature OK\n")
                } catch let RemoteIndexClient.RemoteIndexError.status(code) {
                    return CommandResult(stderr: "pkg: remote index returned HTTP \(code)\n", exitCode: 1)
                } catch RemoteIndexClient.RemoteIndexError.signatureInvalid {
                    return CommandResult(stderr: "pkg: remote index signature verification failed\n", exitCode: 1)
                } catch {
                    return CommandResult(stderr: "pkg: could not fetch remote index\n", exitCode: 1)
                }
            }
            guard let store = packageStore else {
                return CommandResult(stderr: "pkg: no package store configured\n", exitCode: 1)
            }
            let index = PackageIndex.build(from: store, key: indexSigningKey)
            guard index.isValid(key: indexSigningKey) else {
                return CommandResult(stderr: "pkg: index signature verification failed\n", exitCode: 1)
            }
            packageIndex = index
            return CommandResult(stdout: "Updated package index: \(index.entries.count) packages, signature OK\n")

        case "upgrade":
            guard let store = packageStore else {
                return CommandResult(stderr: "pkg: no package store configured\n", exitCode: 1)
            }
            guard let index = packageIndex else {
                return CommandResult(stderr: "pkg: run 'pkg update' first\n", exitCode: 1)
            }
            guard index.isValid(key: indexSigningKey) else {
                return CommandResult(stderr: "pkg: cached index signature invalid\n", exitCode: 1)
            }
            var upgraded: [String] = []
            for name in repository.installed.sorted() {
                guard let entry = index.entry(for: name),
                      let installed = repository.manifest(for: name) else { continue }
                guard entry.version > installed.version else { continue }
                guard let staged = try? store.install(name, into: vfs, prefix: SwiftboxEnvironment.prefix),
                      !staged.isEmpty else { continue }
                // Reflect the new version in the repository so subsequent
                // upgrades see it as current.
                if let archive = try? store.load(name) {
                    repository.publish(archive.manifest)
                }
                repository.markInstalled(name)
                upgraded.append("\(name) -> \(entry.version)")
            }
            if upgraded.isEmpty {
                return CommandResult(stdout: "All packages are up to date\n")
            }
            return CommandResult(stdout: "Upgraded: \(upgraded.joined(separator: ", "))\n")

        default:
            return CommandResult(stderr: "pkg: unknown subcommand '\(sub)'\n", exitCode: 1)
        }
    }

    private func describe(_ error: PackageError) -> String {
        switch error {
        case .unknownPackage(let n): return "Unable to locate package \(n)"
        case .missingDependency(let p, let d): return "\(p) depends on missing package \(d)"
        case .dependencyCycle(let c): return "dependency cycle: \(c.joined(separator: " -> "))"
        case .alreadyInstalled(let n): return "\(n) is already installed"
        case .notInstalled(let n): return "\(n) is not installed"
        case .requiredBy(let p, let dep): return "cannot remove \(p): required by \(dep)"
        }
    }

    /// Shared implementation for `head` / `tail`.
    func headTail(_ args: [String], fromStart: Bool) -> CommandResult {
        var count = 10
        var files: [String] = []
        var i = 0
        let arr = args
        while i < arr.count {
            let a = arr[i]
            if a == "-n", i + 1 < arr.count {
                count = Int(arr[i + 1]) ?? count
                i += 2
                continue
            }
            if a.hasPrefix("-n") {
                count = Int(a.dropFirst(2)) ?? count
            } else if a.hasPrefix("-"), let n = Int(a.dropFirst()) {
                count = n
            } else {
                files.append(a)
            }
            i += 1
        }

        func slice(_ text: String) -> String {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let trailingNewline = lines.last == ""
            if trailingNewline { lines.removeLast() }
            let chosen = fromStart ? Array(lines.prefix(count)) : Array(lines.suffix(count))
            if chosen.isEmpty { return "" }
            return chosen.joined(separator: "\n") + "\n"
        }

        if files.isEmpty {
            guard let piped = takePipedInput() else {
                return CommandResult(stderr: "\(fromStart ? "head" : "tail"): no input\n", exitCode: 1)
            }
            return CommandResult(stdout: slice(piped))
        }
        var out = ""
        for f in files {
            guard let text = try? vfs.readString(resolve(f)) else {
                return CommandResult(stderr: "\(fromStart ? "head" : "tail"): \(f): No such file\n", exitCode: 1)
            }
            out += slice(text)
        }
        return CommandResult(stdout: out)
    }

    /// Collect input for a filter builtin: concatenated file contents, or piped
    /// stdin when no file operands are given. Returns nil with an error result
    /// when neither is available.
    func gatherInput(_ files: [String], command: String) -> (text: String, error: CommandResult?) {
        if files.isEmpty {
            if let piped = takePipedInput() { return (piped, nil) }
            return ("", CommandResult(stderr: "\(command): no input\n", exitCode: 1))
        }
        var text = ""
        for f in files {
            guard let t = try? vfs.readString(resolve(f)) else {
                return ("", CommandResult(stderr: "\(command): \(f): No such file\n", exitCode: 1))
            }
            text += t
        }
        return (text, nil)
    }
}

