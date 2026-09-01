# swiftbox — proxy-only Swift bridge for AdaptiveCards-Mobile

This subfolder is an **experimental, proxy-only** vendored snapshot of
**swiftbox's** pure-Swift core (`SwiftboxCore`). It is a parallel Swift surface
dropped alongside the production mobile SDK — it does **not** alter or wrap any
existing iOS ObjC (`source/ios`), Android Java (`source/android`), or shared C++
(`source/shared`) code.

- **Vendored:** 2026-06-17
- **License:** inherits the repo-root **MIT** license. There is no nested
  `LICENSE` file and no per-file license headers.
- **Substrate pins:** none. `SwiftboxCore` is **pure cross-platform
  `Foundation` Swift** with **zero external package dependencies**, so the
  vendored `Package.swift` declares only the local `SwiftboxCore` target — there
  are no `.package(url:)` lines and therefore no SSH-alias URLs for CI to
  resolve. No `import Darwin / UIKit / AppKit / CoreFoundation / Combine / os.*`.

## What swiftbox is

swiftbox is a Termux-style terminal environment that runs entirely in-process
(no `fork`/`exec`), modelled as pure Swift so it works identically on iOS,
macOS, Linux, and Windows. `SwiftboxCore` provides:

- `VirtualFileSystem` — an in-memory POSIX-like filesystem (the userland
  `$PREFIX`).
- `Shell` + builtins — a command interpreter over that filesystem.
- `SwiftboxEnvironment` — the top-level façade that bootstraps the `$PREFIX`
  userland and wires the filesystem, package repository, and shell together.

## How it relates to AdaptiveCards

The bridge stores and round-trips an Adaptive Card JSON payload through
swiftbox's in-process sandbox: the card is written into the `VirtualFileSystem`,
read back through both the filesystem API and the `Shell`'s `cat` builtin, and
asserted byte-identical. This proves the vendored snapshot's core symbols link
and run end-to-end on Windows MSVC.

## Build (Windows MSVC)

```pwsh
swift build -c debug
```

No vcpkg / zlib is required (pure Foundation).

## Symbols exercised

See `examples/adaptivecards-swiftbox-demo/README.md` for the runtime
symbol-check demo and the list of `SwiftboxCore` symbols it calls.
