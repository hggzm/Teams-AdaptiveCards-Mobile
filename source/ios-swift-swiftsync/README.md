# ios-swift-swiftsync — experimental, proxy-only Swift bridge

This subfolder is a **vendored snapshot of the `SwiftSyncCore` engine** from the
`hggz/swiftsync` Swift-on-Windows kit, dropped alongside the production Adaptive
Cards mobile SDK as an **experimental, proxy-only parallel Swift surface**. It is
not for upstream and it touches **none** of the existing ObjC (`source/ios/`),
Java (`source/android/`), or C++ (`source/shared/cpp/`) code.

- **Vendored as of:** 2026-06-17.
- **License:** this snapshot inherits the repository-root **MIT** license. There
  is no nested `LICENSE` file and no per-file license headers.

## What it is

`SwiftSyncCore` is a general-purpose, pure-Foundation **directory-sync engine** —
a minimalist rsync-style recursive copy with an exhaustively-tested "needs copy?"
decision (destination missing / size differs / source newer), atomic temp+rename
byte copy (never truncating in place), per-entry error capture that never aborts
a run, optional `--exclude` globbing, optional `--delete`, and optional symlink
following. In this bridge it is used headlessly: a host can drive `Syncer`
directly to move Adaptive Card JSON payloads between directories.

## Substrate

**None.** Unlike the NIO-backed bridges, `SwiftSyncCore` has **zero external
package dependencies** and imports only `Foundation`. There are no
`git@github.com-hggz:...` URLs in `Package.swift`, no vcpkg/zlib requirement, and
no Apple-only imports — the terminal/progress UI layer of the original kit
(which used `import Darwin`/`Glibc`/`WinSDK`) is intentionally omitted because the
bridge surface is the headless engine.

## Build (Windows MSVC)

```pwsh
swift build -c debug
```

## Runtime symbol-check demo

`examples/adaptivecards-swiftsync-demo/` is a separate SwiftPM package that
path-deps this snapshot and proves the vendored symbols actually link and run
end-to-end (flavor A — "store / round-trip"): it syncs the canonical
adaptivecards.io "Hello World" card from a temp source directory into a temp
destination directory via the public `Syncer` API, reads it back, and asserts the
bytes are identical, printing `PASS adaptivecards-swiftsync-roundtrip`.

### Symbols exercised

The demo calls these public `SwiftSyncCore` symbols:

- `Syncer(source:destination:options:)` and `Syncer.run()` — drive the recursive sync.
- `Syncer.Options(preservePermissions:exclude:delete:copyLinks:)` — configure it.
- `SyncSummary` / `SyncStats.filesCopied` — assert the tally.
- `FSOps.stat(at:)` and `FSOps.decideCopy(source:destination:)` — confirm the
  post-sync decision is `.skip` (destination already current).
- `HumanSize.string(_:)` — format the transferred byte count for the log line.
