// main.swift
// Flavor A ("store / round-trip") symbol-check demo for the vendored
// swiftci ("jenkins") kit.
//
// Models a real swiftci flow: a build agent collects an artifact (here,
// the canonical adaptivecards.io "Hello World" card) and ships it to the
// controller as a SwiftCIKit.AgentMessage over what would be a WebSocket
// text frame. We exercise that envelope end-to-end in-process:
//
//   1. base64-encode the canonical AdaptiveCard bytes.
//   2. wrap them in AgentMessage.Artifact (tied to a Build whose status
//      is BuildStatus.passed).
//   3. AgentMessage.encodeJSON()           → the on-the-wire string.
//   4. AgentMessage.decode(json:)          → back to a typed message.
//   5. base64-decode the artifact payload  → assert byte-identical to the
//      original card AND that card.type == "AdaptiveCard".
//
// On success prints `PASS adaptivecards-jenkins-roundtrip` and exits 0;
// any deviation prints `FAIL adaptivecards-jenkins-roundtrip: <reason>`
// and exits 1.
//
// Symbols exercised (cross-referenced in README.md):
//   - SwiftCIKit.Build (init)
//   - SwiftCIKit.BuildStatus (.passed)
//   - SwiftCIKit.AgentMessage (enum + .artifact case + pattern match)
//   - SwiftCIKit.AgentMessage.Artifact (init: buildID/name/data)
//   - SwiftCIKit.AgentMessage.encodeJSON()
//   - SwiftCIKit.AgentMessage.decode(json:)

import Foundation
import SwiftCIKit

func runDemo() throws {
    // 1. The canonical sample card bytes + a sanity parse so we know the
    //    oracle itself is a well-formed AdaptiveCard before round-tripping.
    let cardBytes = Data(SampleCard.helloWorldJSON.utf8)
    guard
        let obj = try JSONSerialization.jsonObject(with: cardBytes) as? [String: Any],
        (obj["type"] as? String) == "AdaptiveCard"
    else { throw DemoError.malformedSample }

    // 2. A swiftci Build the artifact belongs to. Touches Build +
    //    BuildStatus so the demo reflects the kit's CI domain, not just
    //    its codec.
    let build = Build(
        jobID: "adaptivecards-demo-job",
        number: 1,
        status: .passed
    )
    // swiftci identifies a build by "<jobID>#<number>" on the wire.
    let buildID = "\(build.jobID)#\(build.number)"

    // 3. Wrap the card as a build Artifact (base64 payload, as the agent
    //    protocol requires for text-frame transport) and put it in an
    //    AgentMessage envelope.
    let payloadB64 = cardBytes.base64EncodedString()
    let artifact = AgentMessage.Artifact(
        buildID: buildID,
        name: "hello-world-card.json",
        data: payloadB64
    )
    let outbound = AgentMessage.artifact(artifact)

    // 4. Serialize to the wire and decode back.
    let wire = try outbound.encodeJSON()
    guard !wire.isEmpty else { throw DemoError.emptyWire }
    let inbound = try AgentMessage.decode(json: wire)

    // 5. Unwrap, base64-decode, and assert byte-identity + card shape.
    guard case let .artifact(roundTripped) = inbound else {
        throw DemoError.wrongCase
    }
    guard roundTripped.buildID == buildID,
          roundTripped.name == "hello-world-card.json" else {
        throw DemoError.metadataMismatch
    }
    guard let decoded = Data(base64Encoded: roundTripped.data) else {
        throw DemoError.badBase64
    }
    guard decoded == cardBytes else {
        throw DemoError.byteMismatch
    }
    guard
        let rtObj = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
        (rtObj["type"] as? String) == "AdaptiveCard"
    else { throw DemoError.roundTripNotACard }
}

// MARK: - Entry

do {
    try runDemo()
    print("PASS adaptivecards-jenkins-roundtrip")
    exit(0)
} catch {
    print("FAIL adaptivecards-jenkins-roundtrip: \(error)")
    exit(1)
}

// MARK: - Demo errors

private enum DemoError: Error, CustomStringConvertible {
    case malformedSample
    case emptyWire
    case wrongCase
    case metadataMismatch
    case badBase64
    case byteMismatch
    case roundTripNotACard

    var description: String {
        switch self {
        case .malformedSample:    return "canonical sample card failed to parse as an AdaptiveCard"
        case .emptyWire:          return "encodeJSON() produced an empty string"
        case .wrongCase:          return "decoded AgentMessage was not the .artifact case"
        case .metadataMismatch:   return "round-tripped artifact buildID/name did not match"
        case .badBase64:          return "round-tripped artifact data was not valid base64"
        case .byteMismatch:       return "round-tripped card bytes differ from the original"
        case .roundTripNotACard:  return "round-tripped payload no longer parses as an AdaptiveCard"
        }
    }
}
