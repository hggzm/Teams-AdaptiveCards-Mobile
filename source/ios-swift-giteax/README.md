# source/ios-swift-giteax

Vendored snapshot of an in-development pure-Swift Gitea-shape git
hosting kit on top of the hggz Swift-on-Windows substrate
(vapor + swift-nio + swift-nio-extras + swift-nio-ssl +
async-http-client + websocket-kit), dropped here as an
**experimental, proxy-only** parallel surface for the Microsoft
Teams Adaptive Cards Mobile repo. Does not touch any existing
`source/ios/`, `source/android/`, or `source/shared/cpp/` shipping
code.

**This subfolder inherits the repo-root MIT LICENSE.** Third-party
trees under `Sources/libgit2/`, `Sources/SwiftGitX/`, and
`Sources/Csqlite3/` retain their upstream attribution — see
[NOTICE.md](./NOTICE.md).

## Layout

```
source/ios-swift-giteax/
  Package.swift                  # SwiftPM manifest, swift-tools-version:5.9
  vcpkg.json                     # Windows-only zlib via vcpkg manifest mode
  NOTICE.md                      # third-party attribution
  README.md                      # you are here
  Sources/
    Giteax/                      # the kit's Swift surface (library)
    GiteaxServer/                # thin main.swift wrapper around configureGiteax
    libgit2/                     # vendored hggz/libgit2 (windows-schannel arm)
    SwiftGitX/                   # vendored hggz/SwiftGitX (msvc-enum-bridging arm)
    Csqlite3/                    # vendored SQLite amalgamation (FTS5 + JSON1 + RTREE)
  examples/
    adaptivecards-giteax-demo/   # runtime symbol-check (Flavor A)
```

## Build (Windows MSVC)

```pwsh
swift build -c debug `
  -Xcc      "-I<repo>/vcpkg_installed/x64-windows-static-md/include" `
  -Xswiftc  "-I<repo>/vcpkg_installed/x64-windows-static-md/include" `
  -Xlinker  "/LIBPATH:<repo>/vcpkg_installed/x64-windows-static-md/lib"
```

The vcpkg manifest at `vcpkg.json` requests zlib; resolve once with
`vcpkg install` before invoking `swift build`. CI does this
automatically (see [.github/workflows/swift-giteax-bridge-gate.yml](../../.github/workflows/swift-giteax-bridge-gate.yml)).

On macOS / Linux the `-X*` flags are unnecessary — the system zlib
is on the default search path.

## Verified

- **`swift build -c debug` (Windows MSVC):** green on Swift 6.3.1.
- **Runtime symbol-check** via
  [examples/adaptivecards-giteax-demo/](examples/adaptivecards-giteax-demo/):
  spins Giteax up in-process against a tempdir, inits a bare repo
  via `SwiftGitX.Repository.create(at:isBare:)` (proving the libgit2
  + Swift C-bridge linkage), creates a user via the admin REST API,
  POSTs the canonical [AdaptiveCards.io "Hello
  World"](https://adaptivecards.io/samples/) sample as the body of
  an issue, GETs it back, asserts byte-equal, and verifies the
  payload is still structurally valid. Prints
  `PASS adaptivecards-giteax-roundtrip` on success.

## What was dropped from the upstream kit

The pure-Swift NIOSSH listener (which depended on a private
`hggz/swift-nio-ssh` fork) is not built in this snapshot. The REST
endpoints for managing per-user SSH public-key strings at
`/api/users/:name/ssh-keys` are still wired, but there is no
on-the-wire SSH listener. HTTPS smart-git over Vapor remains the
exercised git transport.

## Why a vendored snapshot, not a SwiftPM dep

The upstream `hggz/giteax` kit is still iterating in private. A
SwiftPM `path:`-dep would re-leak the private repo identity, and an
HTTPS dep would fail in CI (no SSH key on the runner). Vendoring a
snapshot here is the simplest way to prove the kit's symbols
actually compile and run on a clean Windows MSVC runner without
exposing the in-flight private branches.
