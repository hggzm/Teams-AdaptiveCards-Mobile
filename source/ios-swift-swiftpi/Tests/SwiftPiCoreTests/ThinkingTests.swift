
import Foundation
import Testing
@testable import SwiftPiCore

@Suite("ThinkingLevel & ThinkingConfig")
struct ThinkingTests {
    @Test("raw values match Anthropic level names")
    func rawValues() {
        #expect(ThinkingLevel.off.rawValue == "off")
        #expect(ThinkingLevel.minimal.rawValue == "minimal")
        #expect(ThinkingLevel.low.rawValue == "low")
        #expect(ThinkingLevel.medium.rawValue == "medium")
        #expect(ThinkingLevel.high.rawValue == "high")
        #expect(ThinkingLevel.xhigh.rawValue == "xhigh")
    }

    @Test("ThinkingConfig serializes budget_tokens with snake_case")
    func budgetTokensSnakeCase() throws {
        let config = ThinkingConfig(level: .high, budgetTokens: 8192)
        let data = try JSONEncoder().encode(config)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"budget_tokens\""))
    }

    @Test("ThinkingConfig round-trips with and without budgetTokens")
    func roundTrip() throws {
        let withBudget = ThinkingConfig(level: .medium, budgetTokens: 4096)
        #expect(try TestHelpers.roundTrip(withBudget) == withBudget)
        let withoutBudget = ThinkingConfig(level: .off)
        #expect(try TestHelpers.roundTrip(withoutBudget) == withoutBudget)
    }
}
