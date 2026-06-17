import Foundation

/// A dotted `major.minor.patch` version. Missing components default to 0.
public struct SemanticVersion: Comparable, CustomStringConvertible, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing string: String) {
        let parts = string.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        func num(_ i: Int) -> Int? {
            guard i < parts.count else { return 0 }
            return Int(parts[i])
        }
        guard let ma = num(0), let mi = num(1), let pa = num(2) else { return nil }
        self.init(ma, mi, pa)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (l: SemanticVersion, r: SemanticVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}

/// Metadata describing one installable package — the swiftbox analogue of a
/// Termux `*.deb` control stanza, but every artifact targets the iOS sandbox
/// (`ios-arm64`) rather than Android.
public struct PackageManifest: Equatable {
    public var name: String
    public var version: SemanticVersion
    public var summary: String
    public var dependencies: [String]
    public var homepage: String?
    public var arch: String

    public init(
        name: String,
        version: SemanticVersion,
        summary: String = "",
        dependencies: [String] = [],
        homepage: String? = nil,
        arch: String = "ios-arm64"
    ) {
        self.name = name
        self.version = version
        self.summary = summary
        self.dependencies = dependencies
        self.homepage = homepage
        self.arch = arch
    }
}
