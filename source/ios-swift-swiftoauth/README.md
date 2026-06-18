# ios-swift-swiftoauth

An **experimental, proxy-only** Swift surface vendored alongside the
production Adaptive Cards Mobile iOS (ObjC/C++), Android (Java), and
shared (C++) stacks. It touches none of them.

This is a vendored snapshot of **swiftoauth** — a general-purpose,
Swift-native OAuth 2.0 playground that drives real authorization-code +
PKCE flows and captures the provider callback on a local `127.0.0.1`
loopback server. It builds and runs on **Windows MSVC** (Swift 6.3.1) on
top of the hggz Swift-on-Windows substrate.

**Vendored:** 2026-06-17. This subfolder **inherits the repo-root MIT
license** — there is no nested `LICENSE` file and no per-file license
headers.

## What's here

| Library | Purpose |
|---|---|
| `SwiftOAuthCore` | PKCE (RFC 7636) S256, CSRF `state` (RFC 6749 §10.12), token / identity value types, the GitHub / Discord / Mastodon providers, token store, redaction helpers. Depends on `swift-crypto` only. |
| `SwiftOAuthServer` | The loopback OAuth callback server (RFC 8252): binds `127.0.0.1`, serves one `GET /callback`, validates `state` exactly, and shuts down after one callback. Built on Hummingbird's HTTP/1 runtime. |

The upstream kit also ships a `swiftoauth` CLI executable
(ArgumentParser + AsyncHTTPClient). That front-end is **not** part of
this drop — the bridge vendors only the libraries the symbol-check demo
can `import`.

## Substrate pins

All network dependencies are public `hggz/*` Windows-supported forks,
pinned to the same revisions used by the sibling hggz repos (swiftci,
giteax):

| Package | Revision |
|---|---|
| `hggz/hummingbird` | `3e892143` |
| `hggz/swift-nio` | `7c9c6861` |
| `hggz/swift-nio-extras` | `076c9b49` |
| `apple/swift-crypto` | `from: 3.0.0` (public) |

The committed `Package.swift` contains **no `git@…` SSH URLs** — every
dependency resolves from a public HTTPS remote, so CI can fetch it.

This drop needs **no zlib**: the loopback server uses Hummingbird's
HTTP/1 runtime, which pulls `swift-nio` + `swift-nio-extras` but not
`nio-ssl`/compression.

## Symbols exercised

The mandatory runtime symbol-check demo lives at
[`examples/adaptivecards-swiftoauth-demo/`](examples/adaptivecards-swiftoauth-demo/).
It binds `SwiftOAuthServer.CallbackServer` on `127.0.0.1`, parses the
canonical adaptivecards.io "Hello World" card with Foundation
`JSONDecoder`, and round-trips the derived `body[0].type` fact through a
real loopback HTTP exchange validated by the kit's CSRF `state`. It
exercises `OAuthState`, `PKCE`, `CallbackServerConfig`, `CallbackServer`,
`CallbackServer.RunResult`, and `CallbackOutcome`, then prints
`PASS adaptivecards-swiftoauth-http`. See that folder's README for the
full symbol list.

## Building on Windows

```pwsh
swift build -c debug
cd examples/adaptivecards-swiftoauth-demo
./smoke.ps1
```

CI: [`.github/workflows/swift-swiftoauth-bridge-gate.yml`](../../.github/workflows/swift-swiftoauth-bridge-gate.yml)
(Windows MSVC, build + symbol-check smoke).
