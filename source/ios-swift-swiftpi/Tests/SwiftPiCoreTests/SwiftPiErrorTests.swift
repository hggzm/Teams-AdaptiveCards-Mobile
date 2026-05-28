
import Foundation
import Testing
@testable import SwiftPiCore

@Suite("SwiftPiError")
struct SwiftPiErrorTests {
    @Test("description includes the carried detail string")
    func descriptionFormatting() {
        let cases: [(SwiftPiError, String)] = [
            (.malformedJSON("bad shape"), "bad shape"),
            (.unknownEventType("nope"), "nope"),
            (.iterationLimitExceeded(50), "50"),
            (.capabilityDenied("exec"), "exec"),
            (.io("disk full"), "disk full"),
            (.providerRejected(code: 429, message: "rate"), "rate"),
            (.providerRejected(code: nil, message: "unknown"), "unknown"),
        ]
        for (value, expected) in cases {
            #expect(value.description.contains(expected))
        }
    }

    @Test("Equatable identifies same-shape errors")
    func equatable() {
        #expect(SwiftPiError.io("a") == SwiftPiError.io("a"))
        #expect(SwiftPiError.io("a") != SwiftPiError.io("b"))
        #expect(
            SwiftPiError.providerRejected(code: 500, message: "x")
            ==
            SwiftPiError.providerRejected(code: 500, message: "x")
        )
    }
}

@Suite("SwiftPiCoreVersion")
struct SwiftPiCoreVersionTests {
    @Test("version constants assemble into the expected string")
    func versionString() {
        #expect(SwiftPiCoreVersion.major == 0)
        #expect(SwiftPiCoreVersion.minor == 1)
        #expect(SwiftPiCoreVersion.patch == 0)
        #expect(SwiftPiCoreVersion.versionString == "0.1.0")
    }
}
