# source/ios-swift-swiftharness — SwiftHarness bridge (proxy-only)

Vendored snapshot of the [hggz/swiftharness](https://github.com/hggz/swiftharness)
Swift-on-Windows kit, dropped here as an **experimental, proxy-only**
parallel surface alongside the existing iOS Adaptive Cards SDK. This
subfolder is a SwiftPM package that builds standalone on Windows MSVC
and exposes four library targets the rest of the proxy/integration
work can consume.

This is **not** a replacement for the production Adaptive Cards iOS
SDK (`source/ios/`) and does not touch any existing ObjC, Java, or
C++ shipping code.

## What this subfolder is

A deterministic, inference-free harness runtime:

- A `SessionStore` actor that owns a `.sessions/` directory and
  reads / writes per-session JSON + transcript JSON bundles via a
  cross-platform tmp-then-move atomic write pattern (the workaround
  for `FileManager.replaceItemAt` not being implemented on
  swift-corelibs-foundation on Windows).
- A `ToolRegistry` and a `CommandRegistry` with case-insensitive
  lookup, deterministic message wording, and a sorted-keys JSON wire
  shape suitable for golden-output regression testing.
- A `PermissionPolicy` value that gates tool invocations by
  case-insensitive prefix match.
- Twenty pure inspection verbs over `TranscriptRecord` (`tail`,
  `find`, `range`, `context`, `turn-show`, gap analysis, etc.).

In the proxy/integration context the bridge's primary value is
**storage**: it can persist an AdaptiveCard JSON payload as a turn
prompt, round-trip it through the on-disk format, and emit the
canonical event stream — entirely without any LLM provider, network
client, or platform-specific dependency.

## Vendoring posture

Vendored 2026-05-28. The subfolder inherits the repo-root MIT
license; no nested `LICENSE` file is shipped, no GPL or other
non-MIT per-file headers remain in the vendored sources. No private
commit SHAs, branch names, or phase numbers are referenced.

The original swiftharness package shipped seven targets: four
libraries (Core, Tools, Commands, Session), a Runtime library, a
CLI library, and a CLI executable. The bridge drop only vendors
the **four library targets**:

- `SwiftHarnessCore` — `SessionId`, `TurnIndex`, `Prompt`, `ToolName`,
  `CommandName`, `UsageSummary`, `HarnessError`, `RuntimeEvent`.
- `SwiftHarnessTools` — `ToolDefinition`, `ToolResult`,
  `PermissionPolicy`, `ToolRegistry`.
- `SwiftHarnessCommands` — `CommandDefinition`, `CommandResult`,
  `CommandRegistry`.
- `SwiftHarnessSession` — `Session`, `TranscriptEntry`,
  `TranscriptRecord`, `SessionSelector`, `SessionStore` actor,
  plus 20 transcript inspection verbs.

Runtime and CLI targets are not vendored because the bridge demo
does not need them; future bridge work can pull them in if needed.

## Substrate dependencies

**None.** The vendored targets are Foundation-only and have no
external SwiftPM dependencies. There are no
`git@github.com-hggz:...` SSH URLs anywhere in this manifest.

## Build (Windows MSVC)

```pwsh
cd source/ios-swift-swiftharness
swift build -c debug
```

There is no `swift test` step at the package level — tests live in
the upstream `hggz/swiftharness` repo and are not vendored. The
[runtime symbol-check
example](examples/adaptivecards-swiftharness-demo/README.md) is
what proves the vendored symbols actually link and execute.

## Source tree

```
source/ios-swift-swiftharness/
├── Package.swift                 swift-tools-version:5.9, no external deps
├── README.md                     this file
├── Sources/
│   ├── SwiftHarnessCore/         5 .swift
│   ├── SwiftHarnessTools/        4 .swift
│   ├── SwiftHarnessCommands/     3 .swift
│   └── SwiftHarnessSession/      8 .swift
└── examples/
    └── adaptivecards-swiftharness-demo/   Flavor A: store + round-trip
```

## Why this is here

Per the `hggzm:proxy/integration` workflow, each Swift-on-Windows
kit shipped under `hggz` lands in this repo as a single namespaced
subfolder so that integration with the AdaptiveCards iOS world can
be experimented with in isolation, without touching any of the
production ObjC / C++ code or building any unsanctioned upstream
PRs.
