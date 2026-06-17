# adaptivecards-giteax-demo

Runtime symbol-check example for the vendored `Giteax` kit. Flavor A
("store"): round-trip the canonical
[AdaptiveCards.io](https://adaptivecards.io/samples/) "Hello World"
card payload through Giteax (start in-process, init a bare repo,
authenticate, POST it as an issue body, GET it back, assert
byte-equal).

## What it proves

`swift build` alone proves the vendored kit's manifest parses and the
Swift/C objects link. This demo additionally proves at runtime that:

1. The vendored libgit2 C engine actually loads and a real bare repo
   can be initialised on disk.
2. The vendored SwiftGitX Swift wrapper successfully bridges into
   libgit2 (`Repository.create(at:isBare:)` returns a working repo).
3. `configureGiteax(_:root:)` wires the full REST surface onto a
   caller-owned `Vapor.Application` without throwing.
4. The admin REST API answers and a user can be created.
5. The issue tracker accepts and stores an AdaptiveCard JSON payload
   verbatim as an issue body.
6. A subsequent GET returns the exact same bytes.
7. The round-tripped bytes still decode as a structurally-valid
   AdaptiveCard (`body[0].text` survived).

On success the demo prints `PASS adaptivecards-giteax-roundtrip` and
exits 0. Anything else (build failure, bind failure, non-201 / non-200
status, byte mismatch, structural break) exits non-zero.

## Symbols exercised

These are the Giteax-stack symbols the demo explicitly calls. Listed
here so reviewers can see the surface area covered by a green CI run.

| Symbol | Source | Purpose |
|---|---|---|
| `Giteax.configureGiteax(_:root:)` | `Sources/Giteax/Giteax.swift` | top-level library entry point |
| `SwiftGitX.Repository.create(at:isBare:)` | `Sources/SwiftGitX/Source/Repository.swift` | proves libgit2 + Swift bridge link |
| `Vapor.Application.make(_:)` | hggz/vapor substrate | host app lifecycle |
| `Vapor.Application.execute()` / `asyncShutdown()` | hggz/vapor substrate | run + tear down |
| `POST /api/users` (registered by `registerUserRoutes`) | `Sources/Giteax/UserRoutes.swift` | admin REST surface |
| `POST /api/repos/:u/:r/issues` (registered by `registerIssueRoutes`) | `Sources/Giteax/IssueRoutes.swift` | issue store write |
| `GET  /api/repos/:u/:r/issues/:n` (registered by `registerIssueRoutes`) | `Sources/Giteax/IssueRoutes.swift` | issue store read |
| `GET  /health` | `Sources/Giteax/Giteax.swift` | liveness gate before issuing test calls |

In addition the demo round-trips the canonical card payload through
Foundation `JSONSerialization` to assert structural integrity after
the network hop.

## Run it

### Windows MSVC

```pwsh
./smoke.ps1
```

The script builds the demo, runs it, and greps stdout for the
`PASS adaptivecards-giteax-roundtrip` marker. Exits non-zero on any
failure. The vcpkg-installed zlib include / libpath are threaded
through to SwiftPM via `-Xcc -I` / `-Xlinker /LIBPATH:` (matches what
the parent kit does).

### macOS / Linux

```bash
./smoke.sh
```

No `-X` flags needed; system zlib is on the default search path.

## Layout

```
adaptivecards-giteax-demo/
  Package.swift                                    # path-dep on ../..
  Sources/
    AdaptiveCardsDemo/
      main.swift                                   # the symbol-check body
  smoke.ps1                                        # Windows runner
  smoke.sh                                         # POSIX runner
  README.md                                        # you are here
```
