# adaptivecards-jenkins-demo

Runtime symbol-check example for the vendored `swiftci` ("jenkins") kit,
as required by the proxy-integration ADDENDUM v2 §13.

## What it proves

`swift build` succeeding only proves the manifest parses and the
compiler links. This example additionally proves the vendored kit's
public Swift surface works end-to-end against a real AdaptiveCard JSON
payload, on Windows MSVC.

The demo follows the **Flavor A ("store / round-trip")** template. It
models a real swiftci flow — a build agent collects an artifact and ships
it to the controller as a `SwiftCIKit.AgentMessage` over what would be a
WebSocket text frame — and exercises that envelope in-process:

1. Loads the canonical "Hello World" Adaptive Card
   ([adaptivecards.io/samples](https://adaptivecards.io/samples/)),
   verbatim, and sanity-parses it as an `AdaptiveCard`.
2. Constructs a `SwiftCIKit.Build` (`status: .passed`) and derives its
   `<jobID>#<number>` wire id.
3. Base64-encodes the card bytes and wraps them in a
   `SwiftCIKit.AgentMessage.Artifact`, placed in an
   `AgentMessage.artifact(...)` envelope.
4. Serializes via `AgentMessage.encodeJSON()`, then decodes back via
   `AgentMessage.decode(json:)`.
5. Unwraps the `.artifact` case, base64-decodes the payload, and asserts
   it is **byte-identical** to the original card and still parses with
   `type == "AdaptiveCard"`.

If all five steps pass, the program prints
`PASS adaptivecards-jenkins-roundtrip` and exits 0. Any deviation prints
`FAIL adaptivecards-jenkins-roundtrip: <reason>` and exits 1, which fails
the CI gate.

## Symbols exercised

The demo touches the following public symbols from the vendored
`swiftci` kit. CI logs this list verbatim so reviewers can see the
surface area the demo actually covers.

- `SwiftCIKit.Build` (init)
- `SwiftCIKit.BuildStatus` (`.passed`)
- `SwiftCIKit.AgentMessage` (enum + `.artifact` case + pattern match)
- `SwiftCIKit.AgentMessage.Artifact` (init: `buildID` / `name` / `data`)
- `SwiftCIKit.AgentMessage.encodeJSON()`
- `SwiftCIKit.AgentMessage.decode(json:)`

That's six distinct public symbols, well over the addendum's
"≥3 distinct symbols" minimum, and covers the kit's agent-protocol
codec plus its build-domain types.

## Running

```pwsh
# Windows MSVC (zlib via vcpkg; CI passes -ZlibInc/-ZlibLib)
./smoke.ps1
```

```sh
# Linux / macOS
./smoke.sh
```

Both scripts exit non-zero on failure and search stdout for the literal
line `PASS adaptivecards-jenkins-roundtrip`.

## Layout

```
adaptivecards-jenkins-demo/
  Package.swift                  # path-dep on ../.. (the vendored kit) +
                                 # mirrored hggz substrate pins
  Sources/AdaptiveCardsDemo/
    main.swift                   # the round-trip body
    SampleCard.swift             # canonical adaptivecards.io Hello-World card
  smoke.ps1                      # Windows runner (vcpkg zlib threaded in)
  smoke.sh                       # POSIX runner
  README.md                      # this file
```
