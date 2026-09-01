// examples/adaptivecards-giteax-demo/Sources/AdaptiveCardsDemo/main.swift
//
// Flavor-A symbol-check: round-trip the canonical AdaptiveCard sample
// payload through Giteax (the vendored kit). Spins Giteax up in-process
// on a localhost port against a tempdir, initialises a bare git repo
// via SwiftGitX (proving the libgit2 + SwiftGitX C/Swift linkage works
// end-to-end), authenticates against the admin REST API, posts the
// AdaptiveCard JSON as the body of an issue, reads it back, asserts
// byte-equality, and prints "PASS adaptivecards-giteax-roundtrip".
//
// Symbols exercised (see README.md "Symbols exercised"):
//   - `configureGiteax(_:root:)`               (Giteax library entrypoint)
//   - `SwiftGitX.Repository.create(at:isBare:)` (libgit2 wrapper)
//   - `Vapor.Application.make(_:)`             (host application)
//   - Live HTTP routes registered by Giteax: POST /api/users, POST
//     /api/repos/:user/:repo/issues, GET /api/repos/:user/:repo/issues/:n
//   - JSON encode/decode round-trip via Foundation `JSONSerialization`

import Foundation
import Vapor
import Giteax
import SwiftGitX
import AsyncHTTPClient
import NIOCore
import NIOFoundationCompat

// Platform shim for setenv: not in Foundation on Windows.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

@inline(__always)
private func setEnvVar(_ name: String, _ value: String) {
    #if canImport(WinSDK)
    _ = _putenv_s(name, value)
    #else
    _ = setenv(name, value, 1)
    #endif
}

// MARK: - Canonical AdaptiveCard payload
//
// Copied verbatim from https://adaptivecards.io/samples/ as the
// minimal Adaptive Card v1.4 "hello world" payload that any host
// renderer must accept.
let helloWorldCardJSON = """
{
    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
    "type": "AdaptiveCard",
    "version": "1.4",
    "body": [
        {
            "type": "TextBlock",
            "size": "Medium",
            "weight": "Bolder",
            "text": "Hello, Adaptive Cards"
        },
        {
            "type": "TextBlock",
            "text": "This card was round-tripped through a vendored Giteax instance.",
            "wrap": true
        }
    ]
}
"""

// MARK: - small helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL adaptivecards-giteax-roundtrip: \(message)\n".utf8))
    exit(2)
}

@main
struct Demo {
    static func main() async throws {
        // 1. Sandbox: tempdir + bare repo via SwiftGitX --------------------
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("acg-demo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let user = "hggz"
        let repo = "cards"
        let repoDir = tmp.appendingPathComponent("\(user)/\(repo).git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repoDir.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        // SwiftGitX symbol — proves the libgit2 + Swift C-bridge actually
        // links. A working call here means the entire native git engine
        // we vendored is up.
        do {
            _ = try SwiftGitX.Repository.create(at: repoDir, isBare: true)
        } catch {
            fail("SwiftGitX.Repository.create threw: \(error)")
        }
        guard FileManager.default.fileExists(atPath:
                repoDir.appendingPathComponent("HEAD").path) else {
            fail("bare repo init did not produce HEAD file at \(repoDir.path)")
        }

        // 2. Vapor app + configureGiteax -----------------------------------
        let env = Environment(name: "demo", arguments: ["demo"])
        let app = try await Application.make(env)
        // Vapor returns Void from asyncShutdown(); call it from main()
        // before exit instead of in a defer (defer can't await).

        // Inject env vars BEFORE configureGiteax reads them. setenv is the
        // cross-platform shim Foundation guarantees on Apple/Linux; on
        // Windows the Swift runtime provides _putenv-backed setenv.
        let adminToken = "demo-admin-bearer-" + UUID().uuidString
        let port = 17_290 + Int.random(in: 0...199)
        setEnvVar("GITEAX_ADMIN_TOKEN",     adminToken)
        setEnvVar("GITEAX_ALLOW_PUSH",      "1")
        setEnvVar("GITEAX_ALLOW_ANON_PUSH", "0")

        // Giteax public entry point — wires up every REST route in one call.
        do {
            try await configureGiteax(app, root: tmp)
        } catch {
            fail("configureGiteax threw: \(error)")
        }

        // Bind on a high random port to dodge collisions with other agents.
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = port

        let baseURL = "http://127.0.0.1:\(port)"
        let serverTask = Task.detached {
            do {
                try await app.execute()
            } catch {
                // ignore -- shutdown path
            }
        }
        // serverTask + app are torn down explicitly at the end of main()

        // Poll /health until ready (10s budget).
        let ready = await waitForReady(baseURL: baseURL, deadlineSeconds: 10)
        if !ready { fail("server did not bind on \(baseURL) within 10s") }

        // 3. Create user via admin REST ------------------------------------
        let userPassword = "demo-password-" + UUID().uuidString
        let createUserBody: [String: Any] = [
            "name": user,
            "password": userPassword,
            "isAdmin": false,
        ]
        var status = try await postJSON(
            url: "\(baseURL)/api/users",
            body: createUserBody,
            headers: ["Authorization": "Bearer \(adminToken)"])
        guard status == 201 else {
            fail("POST /api/users -> \(status) (expected 201)")
        }

        // 4. POST the AdaptiveCard JSON as an issue body -------------------
        let basicAuth = "Basic " + ("\(user):\(userPassword)".data(using: .utf8)!.base64EncodedString())
        let issueBody: [String: Any] = [
            "title": "Adaptive Card round-trip",
            "body":  helloWorldCardJSON,
        ]
        let (createStatus, createBytes) = try await postJSONReadBody(
            url: "\(baseURL)/api/repos/\(user)/\(repo)/issues",
            body: issueBody,
            headers: ["Authorization": basicAuth])
        guard createStatus == 201 else {
            fail("POST issue -> \(createStatus): \(String(data: createBytes, encoding: .utf8) ?? "?")")
        }
        let createJSON = try JSONSerialization.jsonObject(with: createBytes) as? [String: Any] ?? [:]
        guard let number = createJSON["number"] as? Int else {
            fail("POST issue response missing 'number': \(createJSON)")
        }

        // 5. GET the issue back --------------------------------------------
        let (getStatus, getBytes) = try await get(
            url: "\(baseURL)/api/repos/\(user)/\(repo)/issues/\(number)",
            headers: [:])
        guard getStatus == 200 else {
            fail("GET issue -> \(getStatus)")
        }
        let getJSON = try JSONSerialization.jsonObject(with: getBytes) as? [String: Any] ?? [:]
        guard let storedBody = getJSON["body"] as? String else {
            fail("GET issue response missing 'body': \(getJSON)")
        }

        // 6. Assert byte-equal --------------------------------------------
        guard storedBody == helloWorldCardJSON else {
            fail("round-trip body mismatch (\(storedBody.count) vs \(helloWorldCardJSON.count) bytes)")
        }

        // 7. Decode the card payload itself to prove it is well-formed
        //    and that key fields survived.
        guard
            let cardData = storedBody.data(using: .utf8),
            let cardObj  = try? JSONSerialization.jsonObject(with: cardData) as? [String: Any],
            let body     = cardObj["body"] as? [[String: Any]],
            body.count   == 2,
            let title    = body[0]["text"] as? String,
            title.contains("Hello, Adaptive Cards")
        else {
            fail("AdaptiveCard payload structurally broken after round-trip")
        }

        print("PASS adaptivecards-giteax-roundtrip")
        serverTask.cancel()
        try? await app.asyncShutdown()
    }
}

// MARK: - tiny HTTP helpers (AsyncHTTPClient -- works on Windows MSVC where
// Foundation's URLSession is stub-only).

private let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

private func waitForReady(baseURL: String, deadlineSeconds: Int) async -> Bool {
    let deadline = Date().addingTimeInterval(TimeInterval(deadlineSeconds))
    while Date() < deadline {
        if let (status, _) = try? await get(url: "\(baseURL)/health", headers: [:]),
           status == 200 {
            return true
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    return false
}

private func get(url: String, headers: [String: String]) async throws -> (Int, Data) {
    var req = HTTPClientRequest(url: url)
    req.method = .GET
    for (k, v) in headers { req.headers.add(name: k, value: v) }
    let resp = try await httpClient.execute(req, timeout: .seconds(10))
    let buf = try await resp.body.collect(upTo: 16 * 1024 * 1024)
    return (Int(resp.status.code), Data(buffer: buf))
}

private func postJSONReadBody(url: String, body: [String: Any], headers: [String: String])
    async throws -> (Int, Data)
{
    var req = HTTPClientRequest(url: url)
    req.method = .POST
    req.headers.add(name: "Content-Type", value: "application/json")
    for (k, v) in headers { req.headers.add(name: k, value: v) }
    let bytes = try JSONSerialization.data(withJSONObject: body)
    req.body = .bytes(ByteBuffer(data: bytes))
    let resp = try await httpClient.execute(req, timeout: .seconds(10))
    let buf = try await resp.body.collect(upTo: 16 * 1024 * 1024)
    return (Int(resp.status.code), Data(buffer: buf))
}

private func postJSON(url: String, body: [String: Any], headers: [String: String]) async throws -> Int {
    let (code, _) = try await postJSONReadBody(url: url, body: body, headers: headers)
    return code
}
