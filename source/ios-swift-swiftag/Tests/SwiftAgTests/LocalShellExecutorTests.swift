import XCTest
@testable import SwiftAg

final class LocalShellExecutorTests: XCTestCase {
    func testEchoCapturesStdout() async throws {
        let exec = LocalShellExecutor(timeout: 10)
        let result = try await exec.execute("echo swiftag-shell-ok")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.stdout.contains("swiftag-shell-ok"),
                      "stdout was: \(result.stdout)")
    }

    func testNonZeroExitPropagates() async throws {
        let exec = LocalShellExecutor(timeout: 10)
        #if os(Windows)
        let result = try await exec.execute("exit 7")
        #else
        let result = try await exec.execute("exit 7")
        #endif
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.timedOut)
    }

    func testShellToolJSONRoundTrip() async throws {
        let tool = ShellTool(executor: LocalShellExecutor(timeout: 10))
        let any = AnyTool(tool)
        let json = try await any.invoke(argumentsJSON: #"{"command":"echo via-shelltool"}"#)
        XCTAssertTrue(json.contains("via-shelltool"), "result was: \(json)")
        XCTAssertTrue(json.contains("\"exitCode\":0"), "result was: \(json)")
    }

    func testShellToolViaRegistry() async throws {
        let reg = ToolRegistry()
        await reg.register(ShellTool(executor: LocalShellExecutor(timeout: 10)))
        let names = await reg.names()
        XCTAssertEqual(names, ["shell"])
        let json = try await reg.invoke(
            name: "shell",
            argumentsJSON: #"{"command":"echo registry-shell"}"#
        )
        XCTAssertTrue(json.contains("registry-shell"))
    }
}
