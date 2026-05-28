# adaptivecards-swiftka-demo

Mandatory runtime symbol-check for the vendored swiftka kit
(`source/ios-swift-swiftka/`).

## What it proves

`swift build` succeeding is the floor (manifest parses, sources
compile, vendored deps link). This demo is the ceiling: it actually
exercises the vendored kit's API end-to-end at runtime against the
canonical AdaptiveCards.io "Hello, AdaptiveCards!" sample card
(copied verbatim into `Sources/AdaptiveCardsDemo/SampleCard.swift`).

The demo follows **Flavor A — "store"** from the integration handoff
addendum:

1. opens a fresh on-disk SQLite database under the OS temp dir,
2. stores the canonical card payload through the bridge,
3. queries its size, reads it back, and asserts byte-for-byte equality,
4. parses the read-back JSON and asserts `"type": "AdaptiveCard"`,
5. prints `PASS adaptivecards-swiftka-roundtrip` on success.

The CI workflow `.github/workflows/swift-swiftka-bridge-gate.yml`
greps for that exact marker on Windows MSVC. No marker → CI fails.

## Symbols exercised

Five distinct vendored symbols are touched, well above the §13
"≥3 distinct symbols" floor:

1. `SwiftKa.version` — public version constant on the kit's umbrella
   type. Proves the `SwiftKaKit` module loads.
2. `Database(path:)` — opens the vendored SQLite 3.47.1 amalgamation
   with WAL + foreign-keys pragmas. Proves the C target links.
3. `KeyStore(database:)` — high-level kv layer the bridge consumes.
   Proves the SwiftPM target graph builds.
4. `AdaptiveCardStore(path:)` — the bridge type that wraps
   Database + KeyStore. Proves the public surface added by
   `SwiftKaBridge` itself works.
5. `AdaptiveCardStore.storeCard / .loadCard / .cardSize` — the
   round-trip APIs the demo exercises against the AdaptiveCards.io
   sample card.

## Running locally

### Windows (pwsh)

```powershell
cd source/ios-swift-swiftka/examples/adaptivecards-swiftka-demo
./smoke.ps1
```

### POSIX (bash)

```bash
cd source/ios-swift-swiftka/examples/adaptivecards-swiftka-demo
./smoke.sh
```

Both scripts run `swift build -c debug` then `swift run -c debug
adaptivecards-swiftka-demo` and exit non-zero unless the binary
prints `PASS adaptivecards-swiftka-roundtrip`.

## Sample card source

[`AdaptiveCards.io / Hello, AdaptiveCards!`](https://adaptivecards.io/samples/)
copied verbatim into
[`Sources/AdaptiveCardsDemo/SampleCard.swift`](Sources/AdaptiveCardsDemo/SampleCard.swift).
