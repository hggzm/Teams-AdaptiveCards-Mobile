import Foundation
import SwiftAg
import SwiftAgProvidersOpenAI

/// A `Terminator` agent that immediately emits a termination message.
/// Used by section 6 of the smoke harness.
private final class Terminator: Agent, @unchecked Sendable {
    let identity = AgentIdentity(name: "terminator")
    func receive(_ message: ChatMessage, from sender: Agent) async throws {}
    func generateReply(to recipient: Agent?) async throws -> AgentReply {
        .message(ChatMessage(role: .assistant, content: "stop. TERMINATE", name: "terminator"))
    }
    func isTerminationMessage(_ message: ChatMessage) -> Bool { true }
}

@main
struct SwiftAgDemo {
    static func main() async throws {
        var failures = 0

        func report(_ section: String, _ ok: Bool, _ detail: String = "") {
            let tag = ok ? "PASS" : "FAIL"
            let suffix = detail.isEmpty ? "" : " — \(detail)"
            print("\(tag)  \(section)\(suffix)")
            if !ok { failures += 1 }
        }

        print("swiftag-demo v\(SwiftAg.version) — functional smoke (no real inference)")
        print(String(repeating: "-", count: 64))

        // 1. Conversable echo round-trip via the provider-less fallback.
        do {
            let alice = ConversableAgent(identity: AgentIdentity(name: "alice"))
            let bob   = ConversableAgent(identity: AgentIdentity(name: "bob"))
            try await alice.send(ChatMessage(role: .user, content: "ping", name: "alice"), to: bob)
            let reply = try await bob.generateReply(to: alice)
            if case let .message(m) = reply, m.content.contains("ping"), m.name == "bob" {
                report("conversable-echo", true, "bob -> \"\(m.content)\"")
            } else {
                report("conversable-echo", false, "got \(reply)")
            }
        }

        // 2. Provider seam — deterministic stub via OpenAIProvider.testing.
        do {
            let provider = OpenAIProvider.testing { msgs in
                LLMResponse(message: ChatMessage(role: .assistant, content: "stub:\(msgs.count)"))
            }
            let agent = ConversableAgent(
                identity: AgentIdentity(name: "responder", systemMessage: "sys"),
                provider: provider
            )
            let peer = ConversableAgent(identity: AgentIdentity(name: "user"))
            try await peer.send(ChatMessage(role: .user, content: "hi"), to: agent)
            let reply = try await agent.generateReply(to: peer)
            if case let .message(m) = reply, m.content == "stub:2" {
                report("provider-stub", true, m.content)
            } else {
                report("provider-stub", false, "got \(reply)")
            }
        }

        // 3. Typed tool invocation (no network, no inference).
        do {
            let tool = WeekdayTool()
            let out = try await tool.invoke(WeekdayInput(date: "2024-01-01"))
            report("tool-typed", out.weekday == "Monday", "2024-01-01 -> \(out.weekday)")
        }

        // 4. JSON-on-the-wire path via ToolRegistry (the LLM-facing surface).
        do {
            let registry = ToolRegistry()
            await registry.register(WeekdayTool())
            let names = await registry.names()
            let result = try await registry.invoke(
                name: "weekday",
                argumentsJSON: #"{"date":"2024-01-01"}"#
            )
            let ok = names == ["weekday"] && result.contains("Monday")
            report("tool-registry", ok, "names=\(names) result=\(result)")
        }

        // 5. GroupChat round-robin across 3 agents for 6 rounds.
        do {
            let a = ConversableAgent(identity: AgentIdentity(name: "a"))
            let b = ConversableAgent(identity: AgentIdentity(name: "b"))
            let c = ConversableAgent(identity: AgentIdentity(name: "c"))
            let chat = GroupChat(
                agents: [a, b, c],
                pattern: RoundRobinPattern(),
                maxRounds: 6
            )
            let transcript = try await chat.run(
                initialMessage: ChatMessage(role: .user, content: "go")
            )
            // 1 opener + 6 replies = 7 messages.
            report("groupchat-roundrobin",
                   transcript.count == 7,
                   "transcript.count=\(transcript.count)")
        }

        // 6. GroupChat termination via TERMINATE marker.
        do {
            let chat = GroupChat(
                agents: [Terminator()],
                pattern: RoundRobinPattern(),
                maxRounds: 100
            )
            let transcript = try await chat.run(
                initialMessage: ChatMessage(role: .user, content: "go")
            )
            let ok = transcript.count == 2
                && transcript.last?.content.contains("TERMINATE") == true
            report("groupchat-terminate", ok, "count=\(transcript.count)")
        }

        // 7. LocalShellExecutor — round-trip a real OS command.
        do {
            let exec = LocalShellExecutor(timeout: 10)
            let result = try await exec.execute("echo swiftag-shell-ok")
            let ok = result.exitCode == 0
                && !result.timedOut
                && result.stdout.contains("swiftag-shell-ok")
            report("shell-executor", ok,
                   "exit=\(result.exitCode) timedOut=\(result.timedOut)")
        }

        // 8. AutoPattern — provider-driven speaker selection via stub.
        do {
            let alice = ConversableAgent(identity: AgentIdentity(name: "alice"))
            let bob   = ConversableAgent(identity: AgentIdentity(name: "bob"))
            let moderator = OpenAIProvider.testing { _ in
                LLMResponse(message: ChatMessage(role: .assistant, content: "bob"))
            }
            let pattern = AutoPattern(provider: moderator)
            let pick = await pattern.selectNext(agents: [alice, bob], history: [])
            report("autopattern-stub",
                   pick?.identity.name == "bob",
                   "picked=\(pick?.identity.name ?? "nil")")
        }

        // 9. UserProxyAgent with a scripted stdin — drives a real
        //    conversational loop without needing a TTY.
        do {
            let source = ScriptedInputSource(["hello there", "TERMINATE"])
            let user = UserProxyAgent(
                identity: AgentIdentity(name: "user"),
                source: source,
                promptPrefix: ""
            )
            let r1 = try await user.generateReply(to: nil)
            let r2 = try await user.generateReply(to: nil)
            let firstOK: Bool
            if case let .message(m) = r1, m.content == "hello there" {
                firstOK = true
            } else {
                firstOK = false
            }
            let secondOK: Bool
            if case .terminate = r2 { secondOK = true } else { secondOK = false }
            report("userproxy-scripted", firstOK && secondOK,
                   "r1=\(r1) r2=\(r2)")
        }

        // 10. SwarmPattern — HANDOFF: <name> in the last message
        //     selects the next speaker.
        do {
            let alpha = ConversableAgent(identity: AgentIdentity(name: "alpha"))
            let beta  = ConversableAgent(identity: AgentIdentity(name: "beta"))
            let pattern = SwarmPattern(initialSpeaker: "alpha")
            let history = [
                ChatMessage(role: .user, content: "go"),
                ChatMessage(role: .assistant,
                            content: "I am alpha. HANDOFF: beta",
                            name: "alpha"),
            ]
            let pick = await pattern.selectNext(agents: [alpha, beta], history: history)
            report("swarm-handoff",
                   pick?.identity.name == "beta",
                   "picked=\(pick?.identity.name ?? "nil")")
        }

        // 11. NestedChat — a researcher backed by an internal
        //     two-agent group chat shows up as one speaker outside.
        do {
            let inner1 = ConversableAgent(identity: AgentIdentity(name: "inner1"))
            let inner2 = ConversableAgent(identity: AgentIdentity(name: "inner2"))
            let researcher = NestedChat(
                identity: AgentIdentity(name: "researcher"),
                agents: [inner1, inner2],
                pattern: RoundRobinPattern(),
                maxRounds: 2
            )
            let planner = ConversableAgent(identity: AgentIdentity(name: "planner"))
            let outer = GroupChat(
                agents: [planner, researcher],
                pattern: RoundRobinPattern(),
                maxRounds: 2
            )
            let transcript = try await outer.run(
                initialMessage: ChatMessage(role: .user, content: "research")
            )
            let ok = transcript.count == 3
                && transcript.last?.name == "researcher"
            report("nestedchat",
                   ok,
                   "count=\(transcript.count) last=\(transcript.last?.name ?? "nil")")
        }

        print(String(repeating: "-", count: 64))
        if failures == 0 {
            print("All smoke checks passed.")
            exit(0)
        } else {
            print("Smoke FAILED — \(failures) failure(s).")
            exit(1)
        }
    }
}
