# adaptivecards-swiftpi-demo

Runtime symbol-check example for the vendored `swiftpi` kit, as
required by the proxy-integration ADDENDUM v2 §13.

## What it proves

`swift build -c debug` succeeding only proves the manifest parses and
the compiler links. This example additionally proves the vendored kit's
public Swift surface area still works end-to-end against a real
AdaptiveCard JSON payload, on Windows MSVC.

The demo follows the **Flavor C ("agent / runtime")** template from the
addendum:

1. Loads the canonical "Hello World" Adaptive Card sample
   ([adaptivecards.io/samples](https://adaptivecards.io/samples/)),
   verbatim, into a `SwiftPiCore.JSONValue`.
2. Constructs a `SwiftPiCore.Agent` with a `SwiftPiCore.FakeProvider`
   tape that emits one `tool_use` turn requesting an
   `adaptivecards_echo` tool with the card as input, then a `text`
   turn closing the conversation.
3. Wires a `SwiftPiCore.Agent.ToolDispatcher` closure that
   round-trips the card unchanged.
4. Drives the agent and asserts the canonical event sequence:
   `agentStart → turnStart → toolUseRequested(adaptivecards_echo) →
   toolResultProduced(isError: false) → turnEnd → turnStart →
   textDelta → turnEnd → agentEnd`.
5. Decodes the tool's returned bytes and confirms `card.type ==
   "AdaptiveCard"`.

If all five steps pass, the program prints
`PASS adaptivecards-swiftpi-agentloop` and exits 0.  
Any deviation prints `FAIL adaptivecards-swiftpi-... : <reason>` and
exits 1, which fails the CI gate.

## Symbols exercised

The demo touches the following public symbols from the vendored
`swiftpi` kit. CI logs this list verbatim so reviewers can see the
surface area the demo actually covers.

- `SwiftPiCore.Agent` (init + `run(initialContext:options:)`)
- `SwiftPiCore.Agent.Capabilities` (fail-closed gate type)
- `SwiftPiCore.Agent.ToolDispatcher` (Sendable closure boundary)
- `SwiftPiCore.Provider` (existential value)
- `SwiftPiCore.FakeProvider` (actor)
- `SwiftPiCore.FakeProviderTape.toolUseTurn`
- `SwiftPiCore.FakeProviderTape.textTurn`
- `SwiftPiCore.Context` (init + `tools`)
- `SwiftPiCore.ToolDef`
- `SwiftPiCore.StreamOptions`
- `SwiftPiCore.JSONValue` (`.object`, `.string`, `.null` cases +
  `Decodable` round-trip)
- `SwiftPiCore.AgentEvent` (`agentStart` / `turnStart` / `textDelta` /
  `toolUseRequested` / `toolResultProduced` / `turnEnd` / `agentEnd`)

That's well over the addendum's "≥3 distinct symbols" minimum and
covers the kit's full event lifecycle.

## Running

```pwsh
# Windows MSVC
./smoke.ps1
```

```sh
# Linux / macOS
./smoke.sh
```

Both scripts exit non-zero on failure and search stdout for the literal
line `PASS adaptivecards-swiftpi-agentloop`.

## Layout

```
adaptivecards-swiftpi-demo/
  Package.swift                  # path-dep on ../.. (the vendored kit)
  Sources/AdaptiveCardsDemo/
    main.swift                   # the demo body
    SampleCard.swift             # canonical Hello-World card payload
  smoke.ps1                      # Windows runner
  smoke.sh                       # POSIX runner
  README.md                      # this file
```
