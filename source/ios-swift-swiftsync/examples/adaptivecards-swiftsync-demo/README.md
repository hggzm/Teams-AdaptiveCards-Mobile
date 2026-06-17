# adaptivecards-swiftsync-demo

A self-contained SwiftPM package that proves the vendored **`SwiftSyncCore`**
snapshot actually links and runs after vendoring — not just that it compiles.

It is **flavor A ("store / round-trip")**: it takes the canonical
adaptivecards.io "Hello World" card, writes it into a temp **source** directory,
drives the vendored `Syncer` to recursively copy that directory into a temp
**destination** directory, reads the card back from the destination, and asserts
the bytes are byte-for-byte identical. It then uses `FSOps` to confirm a second
pass would be a no-op (the pure copy decision is `.skip`).

On success it prints exactly:

```
PASS adaptivecards-swiftsync-roundtrip
```

`smoke.ps1` (Windows) and `smoke.sh` (POSIX) build the demo, run it, and exit
non-zero unless that PASS line is observed. The proxy-only CI gate runs
`smoke.ps1` on Windows MSVC.

## Run

```pwsh
./smoke.ps1
```

```sh
./smoke.sh
```

## Symbols exercised

The demo calls these distinct public `SwiftSyncCore` symbols (well over the
required three):

- `Syncer(source:destination:options:)` and `Syncer.run()` — drive the recursive
  directory sync.
- `Syncer.Options(preservePermissions:exclude:delete:copyLinks:)` — configure it.
- `SyncSummary` and `SyncStats.filesCopied` / `SyncStats.bytesCopied` — assert the
  tally (exactly one file copied) and report the transferred size.
- `FSOps.stat(at:)` and `FSOps.decideCopy(source:destination:)` (returning
  `CopyDecision.skip`) — prove a re-sync is a no-op once the destination is
  current.
- `HumanSize.string(_:)` — format the copied byte count for the log line.
