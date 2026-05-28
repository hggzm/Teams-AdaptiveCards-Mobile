// SwiftPiError — the family of errors raised across swiftpi APIs.
//
// One Swift case per upstream error variant. Specific cases will be
// added as later phases identify them; Phase 1 covers the surface
// SwiftPiCore actually emits today plus the cases other phases are
// guaranteed to need (so downstream signatures don't break later).

import Foundation

public enum SwiftPiError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A JSON document could not be decoded into the expected Swift
    /// shape. The string describes the failure for log/test output.
    case malformedJSON(String)

    /// A streamed event arrived with an unrecognized `type`. The string
    /// is the rejected discriminator.
    case unknownEventType(String)

    /// A bounded loop (e.g. `max_tool_iterations`) was exceeded. The
    /// integer is the limit that fired.
    case iterationLimitExceeded(Int)

    /// A capability check denied a tool invocation. The string names the
    /// capability that was missing.
    case capabilityDenied(String)

    /// A network or I/O operation failed; the string carries the cause.
    case io(String)

    /// A provider rejected the request. The optional code is the
    /// upstream status / error code.
    case providerRejected(code: Int?, message: String)

    public var description: String {
        switch self {
        case .malformedJSON(let detail):
            return "swiftpi: malformed JSON — \(detail)"
        case .unknownEventType(let raw):
            return "swiftpi: unknown stream event type — \(raw)"
        case .iterationLimitExceeded(let limit):
            return "swiftpi: iteration limit exceeded (\(limit))"
        case .capabilityDenied(let capability):
            return "swiftpi: capability denied — \(capability)"
        case .io(let detail):
            return "swiftpi: I/O — \(detail)"
        case .providerRejected(let code, let message):
            if let code {
                return "swiftpi: provider rejected (\(code)) — \(message)"
            }
            return "swiftpi: provider rejected — \(message)"
        }
    }
}
