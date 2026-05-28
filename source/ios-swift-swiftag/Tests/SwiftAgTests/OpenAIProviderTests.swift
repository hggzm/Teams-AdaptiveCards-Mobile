import XCTest
@testable import SwiftAg
@testable import SwiftAgProvidersOpenAI

final class OpenAIProviderTests: XCTestCase {
    func testTestingConstructorReturnsCannedResponse() async throws {
        let provider = OpenAIProvider.testing { _ in
            LLMResponse(message: ChatMessage(role: .assistant, content: "ok"))
        }
        let resp = try await provider.complete(messages: [
            ChatMessage(role: .user, content: "hi")
        ])
        XCTAssertEqual(resp.message.content, "ok")
    }

    func testProductionConstructorThrowsNotYetImplemented() async {
        let provider = OpenAIProvider(
            config: LLMConfig(provider: "openai", model: "gpt-4o", apiKey: "sk-x")
        )
        do {
            _ = try await provider.complete(messages: [])
            XCTFail("expected throw")
        } catch let OpenAIProviderError.notYetImplemented(msg) {
            XCTAssertTrue(msg.contains("HTTP"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConfigIsPreserved() {
        let cfg = LLMConfig(provider: "openai", model: "m", apiKey: "k")
        let provider = OpenAIProvider(config: cfg)
        XCTAssertEqual(provider.config, cfg)
    }
}
