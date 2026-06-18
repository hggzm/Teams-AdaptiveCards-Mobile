# source/ios-swift-swiftka

Proxy-only experimental Swift surface for AdaptiveCards Mobile.

**Vendored from `hggz/swiftka` as of 2026-05-28.** This snapshot inherits
the repo-root MIT license; there is no nested `LICENSE` file. No private
commit SHAs, branch names, or phase numbers are referenced.

## What this is

A SwiftPM package that exposes a small AdaptiveCards-facing surface
(`SwiftKaBridge.AdaptiveCardStore`) on top of the vendored swiftka
kit. swiftka is a pure-Swift Redis-compatible server library; the
bridge uses its key/value storage layer to persist AdaptiveCard JSON
blobs to an on-disk SQLite database (FTS5/JSON1/RTREE-enabled
amalgamation, vendored).

The bridge does **not** touch the shipping ObjC/Java/C++ AdaptiveCards
mobile code. It is parallel surface, intended for prototyping
experimental scenarios (server-side card stores, cross-platform card
sync, etc.) only.

## Layout

```
source/ios-swift-swiftka/
  Package.swift                       — public substrate deps only; no SSH URLs
  Sources/
    Csqlite3/                         — vendored SQLite 3.47.1 amalgamation
    SwiftKaKit/                       — vendored swiftka kit (RESP + storage)
    SwiftKaBridge/                    — thin AdaptiveCards-facing API
  examples/
    adaptivecards-swiftka-demo/       — mandatory runtime symbol-check
      Package.swift
      Sources/AdaptiveCardsDemo/
      smoke.ps1
      smoke.sh
      README.md
```

## Substrate

| Dependency | Pin | Why |
|---|---|---|
| `https://github.com/hggz/swift-nio.git` | `7c9c6861` | Phase-F Windows-substrate fork, public, revision-pinned |

No other private deps. No SSH-alias URLs anywhere in the manifest.

## Build

```powershell
swift build -c debug
```

On Windows the bridge consumes the same Swift-on-Windows substrate as
the rest of the proxy-feature branches (Swift 6.3.1 toolchain, Visual
Studio 2026 C++ tools, no vcpkg deps required for this kit because
the SQLite amalgamation is vendored).

## Runtime symbol-check

The mandatory end-to-end symbol check lives at
`examples/adaptivecards-swiftka-demo/`. Run it on Windows with:

```powershell
cd source/ios-swift-swiftka/examples/adaptivecards-swiftka-demo
./smoke.ps1
```

Or on POSIX:

```bash
cd source/ios-swift-swiftka/examples/adaptivecards-swiftka-demo
./smoke.sh
```

Either script will print `PASS adaptivecards-swiftka-roundtrip` on
success and exit non-zero on failure.
