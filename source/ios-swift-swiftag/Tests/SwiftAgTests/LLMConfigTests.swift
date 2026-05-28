import XCTest
@testable import SwiftAg

final class LLMConfigTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let cfg = LLMConfig(
            provider: "openai",
            model: "gpt-4o",
            temperature: 0.7,
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "sk-test",
            extra: ["org": "acme"]
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(LLMConfig.self, from: data)
        XCTAssertEqual(cfg, decoded)
    }

    func testFromEnvOpenAIDefaults() {
        let cfg = LLMConfig.from(env: [:], provider: "openai")
        XCTAssertEqual(cfg.provider, "openai")
        XCTAssertEqual(cfg.model, "gpt-4o-mini")
        XCTAssertNil(cfg.apiKey)
    }

    func testFromEnvOpenAIOverrides() {
        let cfg = LLMConfig.from(
            env: ["OPENAI_API_KEY": "sk-foo", "OPENAI_MODEL": "gpt-4o"],
            provider: "openai"
        )
        XCTAssertEqual(cfg.apiKey, "sk-foo")
        XCTAssertEqual(cfg.model, "gpt-4o")
    }

    func testFromEnvAnthropicDefaults() {
        let cfg = LLMConfig.from(env: [:], provider: "anthropic")
        XCTAssertEqual(cfg.provider, "anthropic")
        XCTAssertEqual(cfg.model, "claude-3-5-sonnet-latest")
    }

    func testFromEnvUnknownProvider() {
        let cfg = LLMConfig.from(env: [:], provider: "made-up")
        XCTAssertEqual(cfg.provider, "made-up")
        XCTAssertEqual(cfg.model, "")
    }
}
