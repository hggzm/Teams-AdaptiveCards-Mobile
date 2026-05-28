import XCTest
@testable import SwiftAg

final class ToolTests: XCTestCase {
    func testWeekdayKnownDates() async throws {
        let tool = WeekdayTool()
        // 2024-01-01 is a Monday (Gregorian, UTC).
        let mon = try await tool.invoke(WeekdayInput(date: "2024-01-01"))
        let tue = try await tool.invoke(WeekdayInput(date: "2024-01-02"))
        XCTAssertEqual(mon.weekday, "Monday")
        XCTAssertEqual(tue.weekday, "Tuesday")
    }

    func testWeekdayBadDateThrowsInvalidArguments() async {
        let tool = WeekdayTool()
        do {
            _ = try await tool.invoke(WeekdayInput(date: "not a date"))
            XCTFail("expected throw")
        } catch ToolError.invalidArguments {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAnyToolJSONPath() async throws {
        let any = AnyTool(WeekdayTool())
        XCTAssertEqual(any.name, "weekday")
        let result = try await any.invoke(argumentsJSON: #"{"date":"2024-01-01"}"#)
        XCTAssertTrue(result.contains("Monday"), "got \(result)")
    }

    func testAnyToolBadJSONThrowsInvalidArguments() async {
        let any = AnyTool(WeekdayTool())
        do {
            _ = try await any.invoke(argumentsJSON: "not json at all")
            XCTFail("expected throw")
        } catch ToolError.invalidArguments {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRegistryRegisterAndInvoke() async throws {
        let reg = ToolRegistry()
        await reg.register(WeekdayTool())
        let names = await reg.names()
        XCTAssertEqual(names, ["weekday"])
        let result = try await reg.invoke(
            name: "weekday",
            argumentsJSON: #"{"date":"2024-01-01"}"#
        )
        XCTAssertTrue(result.contains("Monday"))
    }

    func testRegistryNotFound() async {
        let reg = ToolRegistry()
        do {
            _ = try await reg.invoke(name: "ghost", argumentsJSON: "{}")
            XCTFail("expected throw")
        } catch ToolError.notFound(let n) {
            XCTAssertEqual(n, "ghost")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testInputSchemaIsValidJSON() throws {
        let tool = WeekdayTool()
        let data = tool.inputSchemaJSON.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(obj is [String: Any])
    }
}
