import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Linux/Windows
#endif

/// Errors specific to HTTP source fetching.
public enum HTTPSourceError: Error, Equatable {
    case notAnHTTPURL(String)
    case requestFailed(String)
    case status(Int)
    case empty
}

/// Abstracts the actual HTTP GET so the networked source provider stays
/// offline-testable: tests inject a stub transport, production uses
/// ``URLSessionTransport``. Keeping this a protocol means no real network call
/// ever happens in `swift test`, and the same provider works on every platform
/// (Foundation's URLSession is available via `FoundationNetworking` off-Apple).
public protocol HTTPTransport {
    /// Perform a GET for `url`, returning the body bytes and HTTP status code.
    func get(_ url: String) throws -> (data: Data, status: Int)
}

/// Synchronous `URLSession`-backed transport. Network fetching is inherently not
/// sandbox-friendly on stock iOS, so this is for the desktop/CLI tooling
/// (`swiftbox-catalog`, host builds) — the on-device app keeps to bundled or
/// cached sources.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }

    public func get(_ url: String) throws -> (data: Data, status: Int) {
        guard let u = URL(string: url) else { throw HTTPSourceError.notAnHTTPURL(url) }
        var request = URLRequest(url: u)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        // Collect the async callback's result into a thread-safe box so the
        // synchronous wrapper is Sendable-clean under the Swift 6 language mode.
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            box.set(data: data,
                    status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                    error: error)
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        let result = box.get()
        if let error = result.error { throw HTTPSourceError.requestFailed("\(error)") }
        guard let data = result.data else { throw HTTPSourceError.empty }
        return (data, result.status)
    }
}

/// A small locked container for handing an async URLSession result back to the
/// synchronous caller without data races.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var status = 0
    private var error: Error?

    func set(data: Data?, status: Int, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        self.data = data; self.status = status; self.error = error
    }

    func get() -> (data: Data?, status: Int, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        return (data, status, error)
    }
}

/// A source provider that fetches a recipe's `TERMUX_PKG_SRCURL` over HTTP(S).
///
/// This is the networked counterpart to ``FileSourceProvider``: it handles
/// `http://` / `https://` URLs, leaving `file://` and local paths to the file
/// provider (combine them with ``ChainSourceProvider``). The integrity check is
/// still applied by ``SourceFetcher`` / ``SourceVerifier`` against
/// `TERMUX_PKG_SHA256`, so a tampered download is rejected exactly as a local
/// one is.
public final class HTTPSourceProvider: SourceProvider {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func fetch(_ recipe: BuildRecipe) throws -> Data {
        guard let url = recipe.metadata.sourceURL,
              url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw SourceError.unavailable(recipe.name)
        }
        let (data, status) = try transport.get(url)
        guard (200...299).contains(status) else { throw HTTPSourceError.status(status) }
        guard !data.isEmpty else { throw HTTPSourceError.empty }
        return data
    }
}

/// Tries each provider in order, returning the first success. Used to prefer a
/// local mirror/cache and fall back to the network: e.g.
/// `ChainSourceProvider([FileSourceProvider(), HTTPSourceProvider()])`.
public final class ChainSourceProvider: SourceProvider {
    private let providers: [SourceProvider]

    public init(_ providers: [SourceProvider]) {
        self.providers = providers
    }

    public func fetch(_ recipe: BuildRecipe) throws -> Data {
        var lastError: Error = SourceError.unavailable(recipe.name)
        for provider in providers {
            do {
                return try provider.fetch(recipe)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
