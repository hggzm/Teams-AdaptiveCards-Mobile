# adaptivecards-swiftag-demo

Mandatory runtime symbol-check for the vendored SwiftAg snapshot. Not
shipped to consumers; CI runs it after `swift build` to prove the
vendored kit links and its symbols actually execute end-to-end.

Flavor: **A (store)** — persist the canonical AdaptiveCards.io
"Hello AdaptiveCards" sample as the content of an Agent
`ChatMessage`, then read it back through the agent's
`ConversationHistory` transcript. Also round-trips the same payload
through a typed `Tool` registered in a `ToolRegistry` to exercise
the JSON-on-the-wire path that an LLM-driven agent would use.

## Sample card

The card embedded at `Sources/AdaptiveCardsDemo/SampleCard.swift` is
copied verbatim from the Schema Explorer "AdaptiveCard" example at
<https://adaptivecards.io/explorer/AdaptiveCard.html>:

```json
{
    "type": "AdaptiveCard",
    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
    "version": "1.5",
    "body": [
        {
            "type": "TextBlock",
            "text": "Hello AdaptiveCards"
        }
    ]
}
```

## Symbols exercised

All from the vendored `SwiftAg` target:

- `AgentIdentity.init(name:systemMessage:description:)`
- `ConversableAgent.init(identity:provider:history:...)`
- `ConversableAgent.send(_:to:)`
- `ConversableAgent.transcript()`
- `ChatMessage.init(role:content:name:toolCallID:)`
- `InMemoryHistory.init(initial:)`
- `ToolRegistry.register(_:)`
- `ToolRegistry.invoke(name:argumentsJSON:)`
- `Tool` protocol conformance (the in-example `CardEchoTool`)

## Observable outcome

On success the binary prints, in order, to stdout:

```
PASS adaptivecards-swiftag-roundtrip
PASS adaptivecards-swiftag-tool
```

and exits 0. On any failure it writes a `FAIL adaptivecards-swiftag-*`
line to stderr and exits non-zero. The smoke scripts grep for the two
`PASS` lines.

## Run locally

```pwsh
# Windows
./smoke.ps1
```

```bash
# POSIX
./smoke.sh
```

Each script runs `swift build -c debug` then `swift run
adaptivecards-swiftag-demo` from this directory and checks the two
PASS lines.
