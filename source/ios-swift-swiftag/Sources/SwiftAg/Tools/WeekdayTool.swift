import Foundation

/// Input for `WeekdayTool`.
public struct WeekdayInput: Codable, Sendable, Hashable {
    public var date: String
    public init(date: String) { self.date = date }
}

/// Output for `WeekdayTool`.
public struct WeekdayOutput: Codable, Sendable, Hashable {
    public var weekday: String
    public init(weekday: String) { self.weekday = weekday }
}

/// Returns the English weekday name (Monday…Sunday) for an ISO date
/// `YYYY-MM-DD` interpreted in UTC. Used by `examples/tool-using-agent`
/// and by the smoke harness; no network, no inference.
public struct WeekdayTool: Tool {
    public typealias Input = WeekdayInput
    public typealias Output = WeekdayOutput

    public let name = "weekday"
    public let description = "Return the English weekday name for an ISO date (YYYY-MM-DD) interpreted in UTC."
    public let inputSchemaJSON = #"{"type":"object","properties":{"date":{"type":"string","description":"ISO 8601 date, YYYY-MM-DD"}},"required":["date"]}"#

    public init() {}

    public func invoke(_ input: Input) async throws -> Output {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: input.date) else {
            throw ToolError.invalidArguments("could not parse date \"\(input.date)\" (expected YYYY-MM-DD)")
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        let idx = cal.component(.weekday, from: date) - 1
        let symbols = cal.weekdaySymbols
        guard idx >= 0, idx < symbols.count else {
            throw ToolError.invocationFailed("weekday index out of bounds: \(idx)")
        }
        return WeekdayOutput(weekday: symbols[idx])
    }
}
