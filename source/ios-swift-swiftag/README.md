# ios-swift-swiftag

> **Proxy-only experimental Swift surface.** Not part of the shipping
> AdaptiveCards iOS SDK. Lives only on `hggz/AdaptiveCards-Mobile`
> and `hggzm/Teams-AdaptiveCards-Mobile` under the
> `proxy/integration` umbrella. Inherits the repo-root MIT license;
> no nested `LICENSE` here.

Vendored on **2026-05-28**. SwiftAg is a general-purpose,
Swift-native multi-agent runtime (`Agent` / `ConversableAgent` /
`GroupChat` patterns / typed `Tool` / `ToolRegistry`) that builds
and runs on macOS, iOS, Linux, **and Windows MSVC** (Swift 6.3.1).
This subfolder ships a snapshot suitable for prototyping
AdaptiveCard-aware agent flows alongside the existing ObjC/C++ SDK
without touching it.

## Layout

```
source/ios-swift-swiftag/
  Package.swift                            # SwiftPM, swift-tools-version:6.0
  Sources/
    SwiftAg/                               # Agent, ConversableAgent, GroupChat,
                                           #   RoundRobinPattern, AutoPattern,
                                           #   SwarmPattern, NestedChat,
                                           #   UserProxyAgent, Tool, ToolRegistry,
                                           #   LocalShellExecutor, ShellTool,
                                           #   InMemoryHistory, LLMConfig
    SwiftAgProvidersOpenAI/                # opt-in provider stub
    SwiftAgProvidersAnthropic/             # opt-in provider stub
    swiftag-demo/                          # 11-section smoke binary
  Tests/SwiftAgTests/                      # 56 XCTest cases
  examples/adaptivecards-swiftag-demo/     # runtime symbol-check (Flavor A:
                                           #   store + retrieve the canonical
                                           #   AdaptiveCards.io Hello sample
                                           #   through an Agent transcript
                                           #   and a ToolRegistry round-trip)
  README.md, NOTICE.md
```

## Relation to the shipping iOS SDK

Zero coupling. This subfolder does **not** touch `source/ios/`,
`source/android/`, or `source/shared/cpp/`. SwiftAg sees an
AdaptiveCard as opaque JSON; it does not parse the schema, render
elements, or wrap any of the ObjC headers. Adopters who want to
combine SwiftAg with the ObjC renderer must bridge at their app
layer.

## Substrate

Pure `Foundation` + Swift stdlib. No `swift-nio`, no `Vapor`, no
`Combine`, no `Darwin/UIKit/AppKit/CoreFoundation`. Builds on every
Swift platform without external system libraries.

## Build

```pwsh
# Windows MSVC (Swift 6.3.1)
cd source/ios-swift-swiftag
swift build -c debug
swift test --parallel

# Run the in-tree 11-section SwiftAg smoke binary (no inference).
swift run swiftag-demo
```

## Symbol-check example

The mandatory runtime symbol-check lives at
[`examples/adaptivecards-swiftag-demo/`](examples/adaptivecards-swiftag-demo/).
See its own `README.md` for the symbol list it exercises and
`smoke.ps1` / `smoke.sh` for the runner.

## Origins

Concepts re-derived from [AG2](https://github.com/ag2ai/ag2)
(Apache-2.0). No upstream Python source translated. See
[`NOTICE.md`](NOTICE.md) for the AG2 + microsoft/autogen
attribution that travels with this snapshot.
