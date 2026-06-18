# adaptivecards-swiftoauth-demo

Runtime symbol-check example for the vendored `swiftoauth` kit, as
required by the proxy-integration ADDENDUM v2 §13.

## What it proves

`swift build -c debug` succeeding only proves the manifest parses and
the compiler links. This example additionally proves the vendored kit's
public Swift surface area still works end-to-end against a real
AdaptiveCard JSON payload, on Windows MSVC.

The demo follows the **Flavor B ("transport / HTTP")** template from the
addendum:

1. Loads the canonical "Hello World" Adaptive Card sample
   ([adaptivecards.io/samples](https://adaptivecards.io/samples/)),
   verbatim, and parses it with Foundation `JSONDecoder`, deriving the
   fact `body[0].type` (== `"TextBlock"`).
2. Generates a CSRF `state` (`SwiftOAuthCore.OAuthState`) and a PKCE
   pair (`SwiftOAuthCore.PKCE`), asserting the pair is RFC 7636-valid.
3. Binds `SwiftOAuthServer.CallbackServer` — the kit's loopback OAuth
   callback server — on the literal `127.0.0.1` (RFC 8252 §7.3) at an
   OS-assigned ephemeral port.
4. From the server's `onBound` hook, issues a real loopback HTTP request
   to the bound URL carrying the derived card fact as the OAuth `code`
   alongside the `state` — the exact shape a provider's browser redirect
   takes (RFC 6749 §4.1.2).
5. The server validates the `state` with a constant-time CSRF check and
   captures the code; the demo asserts the captured code equals the
   derived card fact (`"TextBlock"`) and that the server bound a
   `127.0.0.1` loopback address.

If all steps pass, the program prints
`PASS adaptivecards-swiftoauth-http` and exits 0.  
Any deviation prints `FAIL adaptivecards-swiftoauth-... : <reason>` and
exits 1, which fails the CI gate.

> Note: the kit's loopback server answers `GET /callback` (the OAuth
> redirect shape), so the card fact is round-tripped over a real
> loopback HTTP GET rather than a POST body. This exercises the kit's
> genuine HTTP-server surface instead of fabricating an endpoint the kit
> does not ship.

## Symbols exercised

The demo touches the following public symbols from the vendored
`swiftoauth` kit. CI logs this list verbatim so reviewers can see the
surface area the demo actually covers (well over the addendum's "≥3
distinct symbols" minimum).

- `SwiftOAuthCore.OAuthState` (`generate()`, `.value`, `.matches(_:)`)
- `SwiftOAuthCore.PKCE` (`generate()`, `.codeVerifier`, `.codeChallenge`,
  `isValidVerifier(_:)`, `challenge(for:)`)
- `SwiftOAuthServer.CallbackServerConfig` (`init(expectedState:)`,
  `redirectURI(boundPort:)`)
- `SwiftOAuthServer.CallbackServer` (`init(config:)`, `run(onBound:)`)
- `SwiftOAuthServer.CallbackServer.RunResult` (`.outcome`, `.boundPort`,
  `.redirectURI`)
- `SwiftOAuthServer.CallbackOutcome` (`.code` case)

## Running

```pwsh
./smoke.ps1            # Windows
```

```bash
./smoke.sh             # macOS / Linux
```

This drop does not need zlib (the loopback server uses Hummingbird's
HTTP/1 runtime, not nio-ssl/compression). The `-ZlibInc`/`-ZlibLib`
parameters on `smoke.ps1` are accepted for template compatibility and
are no-ops here.
