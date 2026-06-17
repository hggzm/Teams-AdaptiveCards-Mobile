# source/ios-swift-giteax/NOTICE.md

This subfolder vendors the in-development hggz `Giteax` kit and its
third-party C/Swift dependencies as a snapshot. The vendored snapshot
inherits the repo-root MIT LICENSE for distribution under this
repository, but the third-party trees retain their upstream
attribution as noted below.

## Third-party code under `Sources/`

### `Sources/libgit2/`

Vendored from <https://github.com/hggz/libgit2>'s
`windows-schannel` arm (a fork of upstream
<https://github.com/libgit2/libgit2> 1.9.2 with a Windows MSVC arm
added). The upstream libgit2 project is licensed under the GNU GPL
v2 with a linking exception that explicitly permits use under the
linker exception; the linker exception text is preserved in
`Sources/libgit2/COPYING`. See that file for the full license terms.

### `Sources/SwiftGitX/`

Vendored from <https://github.com/hggz/SwiftGitX>'s
`windows-msvc-enum-bridging` arm (a fork of upstream
<https://github.com/ibrahimcetin/SwiftGitX>). Upstream SwiftGitX is
licensed under the MIT License (see the upstream repo).

### `Sources/Csqlite3/`

Vendored from the SQLite amalgamation distribution at
<https://www.sqlite.org/download.html>. SQLite is released into the
public domain by its authors (see <https://www.sqlite.org/copyright.html>).
The amalgamation header `sqlite3.h` carries the public-domain
notice inline.

## Substrate forks (declared as SwiftPM dependencies, NOT vendored)

These ship as ordinary SwiftPM dependencies in this subfolder's
`Package.swift` and remain on their original upstream licenses:

- `hggz/vapor` (MIT)
- `hggz/swift-nio` (Apache 2.0)
- `hggz/swift-nio-extras` (Apache 2.0)
- `hggz/swift-nio-ssl` (Apache 2.0)
- `hggz/async-http-client` (Apache 2.0)
- `hggz/websocket-kit` (MIT)

## What is intentionally NOT vendored

The pure-Swift NIOSSH listener (depending on a private
`hggz/swift-nio-ssh` fork) is dropped from this snapshot. The REST
endpoints under `/api/users/:name/ssh-keys` for managing per-user SSH
public-key strings are still wired, but there is no on-the-wire SSH
listener in this build. HTTPS smart-git over Vapor remains the
proven git transport.

## Provenance

All vendored sources are reproducible from the public upstreams
listed above. No private commit SHAs, internal branch names, or
phase numbers from the upstream kit's development history are
referenced in this snapshot's commits or PR description.
