// SwiftPiProviders — module documentation namespace.
//
// Phase 7 lands `AnthropicProvider` (Provider implementation backed
// by async-http-client + the SwiftPiStreaming SSE parser) plus the
// `withAnthropicProvider(_:body:)` lifecycle helper. The provider
// targets the Anthropic Messages API directly (`POST /v1/messages`
// with `stream: true`); on success the response body is decoded
// incrementally into `StreamEvent` values that the SwiftPiCore Agent
// consumes verbatim.
//
// The provider is `@unchecked Sendable` (it wraps an `HTTPClient`,
// which is reference-typed but documented thread-safe). It is NOT
// automatically shut down by `deinit` — `HTTPClient` requires an
// explicit async `shutdown()`. Use `withAnthropicProvider` for
// short-lived programs; long-lived deployments instantiate once and
// shut down on app exit.

import SwiftPiCore
import SwiftPiStreaming

public enum SwiftPiProvidersVersion {
    public static let phase: Int = 7
    public static let coreVersion: String = SwiftPiCoreVersion.versionString
}
