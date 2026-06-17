// examples/adaptivecards-swiftbox-demo/Sources/AdaptiveCardsDemo/main.swift
//
// Flavor-A symbol-check: round-trip the canonical AdaptiveCard sample payload
// through swiftbox (the vendored kit). Bootstraps a swiftbox in-process sandbox,
// stores the card JSON in the VirtualFileSystem under the userland $HOME, reads
// it back through both the filesystem API and the Shell's `cat` builtin, asserts
// byte-equality, decodes the payload to confirm it is a well-formed Adaptive
// Card, and prints "PASS adaptivecards-swiftbox-roundtrip".
//
// Symbols exercised (see README.md "Symbols exercised"):
//   - `SwiftboxEnvironment.init(container:runProfile:allowNetwork:)`  (sandbox bootstrap)
//   - `SwiftboxEnvironment.home` / `.version`                         (userland layout)
//   - `VirtualFileSystem.makeDirectory(_:createIntermediates:)`       (store)
//   - `VirtualFileSystem.writeFile(_:string:)`                        (store)
//   - `VirtualFileSystem.isFile(_:)`                                  (verify)
//   - `VirtualFileSystem.readString(_:)`                              (read back)
//   - `Shell.run(_:)`                                                 (command interpreter / `cat`)

import Foundation
import SwiftboxCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL adaptivecards-swiftbox-roundtrip: \(message)\n".utf8))
    exit(2)
}

// 1. Bootstrap the swiftbox in-process sandbox (ephemeral: no on-disk container).
let environment = SwiftboxEnvironment()
let shell = environment.shell
let vfs = shell.vfs

// 2. Store the card under the userland $HOME via the virtual filesystem.
let cardsDir = SwiftboxEnvironment.home + "/cards"
do {
    _ = try vfs.makeDirectory(cardsDir)
} catch {
    fail("VirtualFileSystem.makeDirectory threw: \(error)")
}

let cardPath = cardsDir + "/hello.json"
do {
    try vfs.writeFile(cardPath, string: helloWorldCardJSON)
} catch {
    fail("VirtualFileSystem.writeFile threw: \(error)")
}

guard vfs.isFile(cardPath) else {
    fail("card was not stored at \(cardPath)")
}

// 3. Read it back through the filesystem API; assert byte-identical.
let readBack: String
do {
    readBack = try vfs.readString(cardPath)
} catch {
    fail("VirtualFileSystem.readString threw: \(error)")
}
guard readBack == helloWorldCardJSON else {
    fail("VFS round-trip mismatch (\(readBack.utf8.count) vs \(helloWorldCardJSON.utf8.count) bytes)")
}

// 4. Read it back through the Shell's `cat` builtin (the command interpreter);
//    assert it carries the card text.
let catResult = shell.run("cat \(cardPath)")
guard catResult.exitCode == 0 else {
    fail("shell `cat` exit=\(catResult.exitCode): \(catResult.stderr)")
}
guard catResult.stdout.contains("Hello, Adaptive Cards") else {
    fail("shell `cat` did not return the card text; got: \(catResult.stdout.prefix(120))")
}

// 5. Decode the stored payload to confirm it is a well-formed Adaptive Card and
//    key fields survived the round-trip.
guard
    let cardData = readBack.data(using: .utf8),
    let card = try? JSONSerialization.jsonObject(with: cardData) as? [String: Any],
    (card["type"] as? String) == "AdaptiveCard",
    let body = card["body"] as? [[String: Any]],
    let firstType = body.first?["type"] as? String,
    firstType == "TextBlock"
else {
    fail("stored payload is not a well-formed AdaptiveCard")
}

print("swiftbox \(SwiftboxEnvironment.version): stored + round-tripped a "
    + "\(helloWorldCardJSON.utf8.count)-byte Adaptive Card via VirtualFileSystem "
    + "and the Shell `cat` builtin; body has \(body.count) items, body[0].type = \(firstType)")
print("PASS adaptivecards-swiftbox-roundtrip")
