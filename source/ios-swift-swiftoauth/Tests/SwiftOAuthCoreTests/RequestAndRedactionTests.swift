import Testing
import Foundation
@testable import SwiftOAuthCore

@Suite struct HTTPRequestTests {
    @Test func formPOSTSetsContentTypeAndSortedBody() {
        let url = URL(string: "https://example.com/token")!
        let request = HTTPRequest.formPOST(url: url, fields: ["b": "2", "a": "1"])
        #expect(request.method == .POST)
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self) == "a=1&b=2")
    }

    @Test func formEncodingPercentEscapesAndSortsKeys() {
        let encoded = FormURLEncoding.encode([
            "redirect_uri": "http://127.0.0.1:8080/callback",
            "code": "a b",
        ])
        #expect(encoded == "code=a%20b&redirect_uri=http%3A%2F%2F127.0.0.1%3A8080%2Fcallback")
    }

    @Test func redactedDescriptionMasksAuthorization() {
        let url = URL(string: "https://api.github.com/user")!
        let request = HTTPRequest(method: .GET, url: url, headers: [
            "Authorization": "Bearer SUPERSECRET",
            "Accept": "application/json",
        ])
        let description = request.redactedDescription
        #expect(!description.contains("SUPERSECRET"))
        #expect(description.contains(Redaction.placeholder))
        #expect(description.contains("application/json"))
    }
}

@Suite struct RedactionTests {
    @Test func redactHeadersMasksSensitiveOnly() {
        let redacted = Redaction.redactHeaders([
            "Authorization": "Bearer x",
            "Cookie": "s=1",
            "Accept": "application/json",
        ])
        #expect(redacted["Authorization"] == Redaction.placeholder)
        #expect(redacted["Cookie"] == Redaction.placeholder)
        #expect(redacted["Accept"] == "application/json")
    }

    @Test func redactTokenDefaultAndPrefixHint() {
        #expect(Redaction.redactToken("supersecret") == Redaction.placeholder)
        let hinted = Redaction.redactToken("supersecret", keepingPrefix: 4)
        #expect(hinted.hasPrefix("supe"))
        #expect(!hinted.contains("secret"))
    }

    @Test func redactTokenJSONMasksTokenValues() {
        let body = #"{"access_token":"AAA","refresh_token":"BBB","token_type":"bearer"}"#
        let redacted = Redaction.redactTokenJSON(body)
        #expect(!redacted.contains("AAA"))
        #expect(!redacted.contains("BBB"))
        #expect(redacted.contains("bearer"))
    }
}
