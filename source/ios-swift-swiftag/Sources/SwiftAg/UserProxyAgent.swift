import Foundation

/// Source of human-typed input for `UserProxyAgent`. The default
/// (`StdinInputSource`) reads a line from `FileHandle.standardInput`;
/// tests and the smoke harness can inject a `ScriptedInputSource`
/// to drive the agent deterministically.
public protocol UserInputSource: Sendable {
    /// Prompt the user (or scripted source) for input. Returns `nil`
    /// at end-of-stream.
    func readLine(prompt: String) async -> String?
}

/// Reads one line from real stdin per call.
public struct StdinInputSource: UserInputSource {
    public init() {}

    public func readLine(prompt: String) async -> String? {
        if !prompt.isEmpty {
            FileHandle.standardOutput.write(Data(prompt.utf8))
        }
        return Swift.readLine(strippingNewline: true)
    }
}

/// Deterministic stand-in for stdin. Hands out the next entry from a
/// fixed script per `readLine`. After exhaustion, returns `nil`.
public actor ScriptedInputSource: UserInputSource {
    private var lines: [String]
    private(set) public var prompts: [String] = []

    public init(_ lines: [String]) { self.lines = lines }

    public func readLine(prompt: String) -> String? {
        prompts.append(prompt)
        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }

    public func remaining() -> [String] { lines }
}

/// Agent that delegates `generateReply` to a `UserInputSource`. The
/// default human-input mode is `.always`, matching AG2's
/// `UserProxyAgent` behaviour: the agent itself does not emit
/// machine-authored content. When the input source reports `nil`
/// (EOF) the conversation terminates.
public actor UserProxyAgent: Agent {
    public nonisolated let identity: AgentIdentity
    public nonisolated let humanInputMode: HumanInputMode

    private let source: any UserInputSource
    private let history: any ConversationHistory
    private let promptPrefix: String

    public init(
        identity: AgentIdentity,
        source: any UserInputSource = StdinInputSource(),
        history: any ConversationHistory = InMemoryHistory(),
        humanInputMode: HumanInputMode = .always,
        promptPrefix: String? = nil
    ) {
        self.identity = identity
        self.source = source
        self.history = history
        self.humanInputMode = humanInputMode
        self.promptPrefix = promptPrefix ?? "\(identity.name)> "
    }

    public func transcript() async -> [ChatMessage] {
        await history.all()
    }

    // MARK: - Agent

    nonisolated public func isTerminationMessage(_ message: ChatMessage) -> Bool {
        message.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .hasSuffix("TERMINATE")
    }

    public func receive(_ message: ChatMessage, from sender: Agent) async throws {
        await history.append(message)
    }

    public func generateReply(to recipient: Agent?) async throws -> AgentReply {
        guard let line = await source.readLine(prompt: promptPrefix) else {
            return .terminate(reason: "user input EOF")
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .terminate(reason: "empty user input")
        }
        let message = ChatMessage(role: .user, content: line, name: identity.name)
        await history.append(message)
        if isTerminationMessage(message) {
            return .terminate(reason: "user requested TERMINATE")
        }
        return .message(message)
    }
}
