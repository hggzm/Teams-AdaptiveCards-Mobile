# source/ios-swift-jenkins

Swift-native CI/CD controller + build-agent kit ("swiftci"), vendored
into this repo as an experimental, proxy-only parallel surface alongside
the production ObjC / Java / C++ AdaptiveCards stack.

- **Vendored from** `hggz/swiftci` (the Swift-on-Windows "swiftjenkins" kit)
- **Vendor date** 2026-06-17
- **License** this subfolder inherits the repo-root MIT license. The
  non-MIT per-file headers (if any) were stripped per the
  proxy-integration ADDENDUM-v2 rules. No nested `LICENSE` file.
- **Edits to existing source** none. This folder does not touch
  `source/ios/`, `source/android/`, or `source/shared/cpp/`.

## What it is

`swiftci` is a minimalist, self-hostable continuous-integration system —
a Jenkins-shaped controller plus a WebSocket-connected build agent —
written in pure cross-platform Swift on the hggz Vapor-on-Windows
substrate. The integration surface this branch exercises is its
**agent wire protocol**: the controller and agents exchange typed
`AgentMessage` envelopes (register / log / artifact / buildFinished /
runBuild / cancelBuild), and an AdaptiveCard payload rides across that
protocol as a build artifact, proving the kit links and round-trips real
data on Windows MSVC.

## Tech substrate

Pinned to the same public hggz Swift-on-Windows forks that ship in
`hggz/swiftci` itself (Phase F, revision-pinned):

| Package | Pin |
|---|---|
| `hggz/vapor` | `5d21fd1e` |
| `hggz/swift-nio` | `7c9c6861` |
| `hggz/swift-nio-extras` | `076c9b49` |
| `hggz/swift-nio-ssl` | `7f9efd5` |
| `hggz/async-http-client` | `eaaf46a` |
| `hggz/websocket-kit` | `ddfba8c` |
| `jpsim/Yams` | from `5.0.0` |

All hggz pins are public forks at https URLs; no `git@github.com-hggz:...`
URLs appear in the manifest (verified by CI).

## Products

- `.library SwiftCIKit` — controller + agent shared types and services
  (this is what the demo consumes).
- `.executable swiftci` — the controller server.
- `.executable swiftci-agent` — the build agent.

## Build (Windows MSVC)

The Vapor/NIO substrate pulls `NIOHTTPCompression`, whose `CNIOExtrasZlib`
C module needs `<zlib.h>`. Install zlib via vcpkg manifest mode (the
vendored `vcpkg.json`), then thread it in:

```
swift build -c debug `
  -Xcc      "-I<vcpkg>/include" `
  -Xswiftc  "-I<vcpkg>/include" `
  -Xlinker  "/LIBPATH:<vcpkg>/lib"
```

## Runtime symbol-check example

See [`examples/adaptivecards-jenkins-demo/`](examples/adaptivecards-jenkins-demo/).
That example is the gating proof: CI runs `smoke.ps1`, which builds and
executes the demo and greps for `PASS adaptivecards-jenkins-roundtrip`.

## Cross-platform discipline

- No `import Darwin / UIKit / AppKit / CoreFoundation / Combine / os.*`
  anywhere in `Sources/` or `Tests/`.
- LF line endings throughout (`.gitattributes` enforces it). CRLF in
  source breaks the Swift-on-Windows build path and Linux CI.
- `Foundation` + Vapor/NIO only, so the same code paths run on macOS,
  Linux, and Windows.
