import Foundation

/// Publishes and fetches a signed ``PackageIndex`` over HTTP.
///
/// This is the distribution half of the package system: a server hosts the
/// `.sboxindex` bytes produced by ``PackageIndex/encoded()``, and a client
/// fetches them with `pkg update <url>`, decodes them, and **verifies the
/// signature before trusting any entry**. Fetching goes through the same
/// injectable ``HTTPTransport`` as source downloads, so the whole flow is
/// offline-testable with a stub and works on every platform.
public final class RemoteIndexClient {
    private let transport: HTTPTransport
    private let signingKey: String

    public init(transport: HTTPTransport = URLSessionTransport(), signingKey: String) {
        self.transport = transport
        self.signingKey = signingKey
    }

    public enum RemoteIndexError: Error, Equatable {
        case notAnHTTPURL(String)
        case status(Int)
        case empty
        case malformed(String)
        case signatureInvalid
    }

    /// Fetch, decode and verify a signed index from `url`. Throws unless the
    /// signature matches the client's signing key.
    public func fetch(_ url: String) throws -> PackageIndex {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw RemoteIndexError.notAnHTTPURL(url)
        }
        let (data, status) = try transport.get(url)
        guard (200...299).contains(status) else { throw RemoteIndexError.status(status) }
        guard !data.isEmpty else { throw RemoteIndexError.empty }

        let index: PackageIndex
        do {
            index = try PackageIndex.decode(data)
        } catch {
            throw RemoteIndexError.malformed("\(error)")
        }
        guard index.isValid(key: signingKey) else { throw RemoteIndexError.signatureInvalid }
        return index
    }
}
