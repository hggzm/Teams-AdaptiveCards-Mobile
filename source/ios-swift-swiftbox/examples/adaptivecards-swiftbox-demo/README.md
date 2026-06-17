# adaptivecards-swiftbox-demo

A self-contained runtime symbol-check for the vendored **swiftbox** kit
(`../..`). It proves the vendored snapshot's core symbols link and run
end-to-end on Windows MSVC — a green `swift build` alone is only the floor.

## What it proves (Flavor A — store / round-trip)

1. Bootstraps a swiftbox in-process sandbox (`SwiftboxEnvironment`).
2. Takes the canonical [adaptivecards.io](https://adaptivecards.io/samples/)
   "Hello World" card JSON (see `SampleCard.swift`, copied verbatim).
3. Stores it in the sandbox's `VirtualFileSystem` under the userland `$HOME`.
4. Reads it back through **both** the filesystem API **and** the `Shell`'s `cat`
   builtin.
5. Asserts the read-back bytes equal the original, and decodes the payload to
   confirm it is a well-formed `AdaptiveCard` (`type`, `body[0].type ==
   "TextBlock"`).
6. Prints `PASS adaptivecards-swiftbox-roundtrip` on success.

`smoke.ps1` (Windows) and `smoke.sh` (POSIX) build, run, and grep for the PASS
line, exiting non-zero on any failure. No vcpkg / zlib is required — swiftbox is
pure `Foundation`.

## Symbols exercised

- `SwiftboxEnvironment.init(container:runProfile:allowNetwork:)` — bootstrap the sandbox
- `SwiftboxEnvironment.home` — userland `$HOME` path
- `SwiftboxEnvironment.version` — reported in the PASS summary line
- `VirtualFileSystem.makeDirectory(_:createIntermediates:)` — create the cards dir
- `VirtualFileSystem.writeFile(_:string:)` — store the card JSON
- `VirtualFileSystem.isFile(_:)` — verify it was stored
- `VirtualFileSystem.readString(_:)` — read the card back
- `Shell.run(_:)` — drive the `cat` builtin (the command interpreter) over the stored file
