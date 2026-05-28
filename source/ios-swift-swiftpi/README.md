# source/ios-swift-swiftpi

Swift-native AI coding agent CLI ("swiftpi"), vendored into this repo as
an experimental, proxy-only parallel surface alongside the production
ObjC / Java / C++ AdaptiveCards stack.

- **Vendored from** `hggz/swiftpi`
- **Vendor date** 2026-05-28
- **License** this subfolder inherits the repo-root MIT license. The
  upstream `hggz/swiftpi` ships under GPLv3-or-later; the snapshot
  committed here has its non-MIT per-file headers stripped per the
  proxy-integration ADDENDUM-v2 rules. No nested `LICENSE` file.
- **Edits to existing source** none. This folder does not touch
  `source/ios/`, `source/android/`, or `source/shared/cpp/`.

## What it is

`swiftpi` is a small, provider-agnostic Swift agent runtime that can
drive a tool-using LLM turn against:

- a recorded `FakeProvider` tape (deterministic; used in tests and in
  the demo here),
- the Anthropic Messages API over `async-http-client`.

The integration surface this branch exercises is:

- The AdaptiveCard JSON payload is treated as a tool input/output. A
  Fake provider scripts an assistant turn that calls a single
  registered tool (`adaptivecards_echo`) with the canonical
  "Hello AdaptiveCards" sample card, the tool returns the same payload
  back, and the agent emits the canonical event sequence:
  `agent_start → text_delta → tool_use → tool_result → text_delta → agent_end`.

This proves the vendored kit links and runs end-to-end on Windows MSVC
against a real AdaptiveCards payload.

## Tech substrate

Pinned to the same hggz Swift-on-Windows substrate that ships in
`hggz/swiftci`, `hggz/giteax`, and `hggz/swiftpi` itself:

| Package | Pin |
|---|---|
| `hggz/swift-nio` | `7c9c6861` |
| `hggz/swift-nio-extras` | `076c9b49` |
| `hggz/swift-nio-ssl` | `7f9efd5` |
| `hggz/async-http-client` | `eaaf46a` |

All four hggz pins are public forks; no `git@github.com-hggz:...`
URLs appear in the manifest (verified by CI). The original
upstream-swiftpi pin on `apple/swift-argument-parser` has been
dropped here because the executable target it served was removed
from this snapshot.

## Build (Windows MSVC)

```
swift build -c debug
swift test --parallel
```

On Windows, `NIOHTTPCompression` (transitive via `async-http-client`)
needs zlib, which is declared in `vcpkg.json` next to `Package.swift`.
CI installs zlib via vcpkg manifest mode and passes
`-Xcc / -Xswiftc / -Xlinker` flags pointing at
`vcpkg_installed/x64-windows-static-md/`. macOS and Linux find
zlib on the system path and need no flags.

## Runtime symbol-check example

See [`examples/adaptivecards-swiftpi-demo/`](examples/adaptivecards-swiftpi-demo/).
That example is the gating proof: CI runs `smoke.ps1`, which builds and
executes the demo and greps for `PASS adaptivecards-swiftpi-agentloop`.

## Cross-platform discipline

- No `import Darwin / UIKit / AppKit / CoreFoundation / Combine / os.*`
  anywhere in `Sources/` or `Tests/`.
- LF line endings throughout. CRLF in source breaks the Swift-on-Windows
  build path.
- `Foundation` only at API boundaries; everything network goes through
  `AsyncHTTPClient` / NIO so the same code paths run on macOS, Linux,
  and Windows.
