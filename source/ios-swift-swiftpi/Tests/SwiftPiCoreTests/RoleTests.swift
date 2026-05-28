
import Foundation
import Testing
@testable import SwiftPiCore

@Suite("Role")
struct RoleTests {
    @Test("all raw values are the documented lowercase strings")
    func rawValues() {
        #expect(Role.user.rawValue == "user")
        #expect(Role.assistant.rawValue == "assistant")
        #expect(Role.system.rawValue == "system")
    }

    @Test("decoding from JSON string round-trips")
    func roundTrip() throws {
        for role in Role.allCases {
            let data = try JSONEncoder().encode(role)
            let restored = try JSONDecoder().decode(Role.self, from: data)
            #expect(restored == role)
        }
    }

    @Test("unknown role string fails to decode")
    func unknownRole() {
        let data = "\"banana\"".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Role.self, from: data)
        }
    }
}
