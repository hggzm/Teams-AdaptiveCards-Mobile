# adaptivecards-swiftharness-demo

Runtime symbol-check for the vendored
[`source/ios-swift-swiftharness`](../..) bridge. Drives a real
store-and-retrieve round trip of the canonical
[AdaptiveCards.io](https://adaptivecards.io/samples/) "Hello World"
sample card through the vendored `SessionStore` actor, then asserts
the JSON bytes survived a tmp-then-move on-disk persistence cycle and
that the transcript inspection verb can find them by content.

This is **Flavor A** ("store") from the integration handoff: the
swiftharness kit's primary value is deterministic on-disk persistence
of structured turn data, so the demo persists the card, reads it back,
and confirms it round-trips.

The demo exits non-zero on any deviation from the expected outcome.
On success, it prints exactly one line to stdout:

```
PASS adaptivecards-swiftharness-roundtrip
```

The `smoke.ps1` / `smoke.sh` wrappers `swift build`, `swift run`,
and grep for that exact string. CI fails if it is absent.

## Symbols exercised

The demo touches the following symbols from the vendored kit. CI
logs the demo source verbatim so reviewers can see the surface area
covered.

| Symbol | Origin |
|---|---|
| `SessionStore(root:)` | `SwiftHarnessSession/SessionStore.swift` |
| `SessionStore.createSession()` | `SwiftHarnessSession/SessionStore.swift` |
| `SessionStore.appendTurn(_:prompt:)` | `SwiftHarnessSession/SessionStore.swift` |
| `SessionStore.loadTranscript(_:)` | `SwiftHarnessSession/SessionStore.swift` |
| `TranscriptRecord.find(query:)` | `SwiftHarnessSession/TranscriptInspection.swift` |
| `Prompt(_:)` | `SwiftHarnessCore/Names.swift` |

Six symbols from two of the four vendored library targets
(`SwiftHarnessCore`, `SwiftHarnessSession`) — well over the
addendum's ≥ 3 minimum.

## Layout

```
adaptivecards-swiftharness-demo/
├── Package.swift                                    swift-tools-version:5.9, path-deps the bridge
├── README.md                                        this file
├── Sources/AdaptiveCardsDemo/
│   ├── main.swift                                   the round-trip body + PASS print
│   └── SampleCard.swift                             canonical AdaptiveCard JSON literal
├── smoke.ps1                                        Windows runner
└── smoke.sh                                         POSIX runner
```

## Run

### Windows

```pwsh
pwsh -NoProfile -ExecutionPolicy Bypass -File .\smoke.ps1
```

### POSIX

```sh
sh smoke.sh
```

Both runners exit non-zero on any failure.
