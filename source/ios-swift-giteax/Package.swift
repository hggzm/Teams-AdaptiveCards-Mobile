// swift-tools-version:5.9
//
// source/ios-swift-giteax/Package.swift -- proxy/feat-swift-giteax-bridge
//
// Vendored snapshot of an in-development Swift git-hosting kit on top of
// the hggz Swift-on-Windows substrate (vapor + swift-nio + swift-nio-extras
// + swift-nio-ssl + async-http-client + websocket-kit). All previously
// private SwiftPM deps (libgit2 fork, SwiftGitX) are vendored inline here
// as local targets so this manifest contains zero `git@...` SSH URLs.
//
// The pure-Swift NIOSSH listener was dropped from this snapshot to avoid
// vendoring the swift-nio-ssh fork as well; the REST endpoints that
// manage per-user SSH key strings are still here, but no on-the-wire
// SSH listener is built. HTTP/HTTPS smart-git and the REST surface are
// the proven path.
//
// This subfolder inherits the repo-root MIT LICENSE. The third-party C
// + Swift code under Sources/libgit2/ and Sources/SwiftGitX/ retains its
// own upstream attribution -- see NOTICE.md.
//
// Windows MSVC build invocation (from this directory):
//   swift build -c debug \
//     -Xcc      "-I<repo>/vcpkg_installed/x64-windows-static-md/include" \
//     -Xswiftc  "-I<repo>/vcpkg_installed/x64-windows-static-md/include" \
//     -Xlinker  "/LIBPATH:<repo>/vcpkg_installed/x64-windows-static-md/lib"

import PackageDescription

// =============================================================================
// libgit2 cSettings / excludedPaths / linkerSettings
// -----------------------------------------------------------------------------
// Transcribed from hggz/libgit2:windows-schannel/Package.swift. Three-armed
// build (macOS / Windows / Linux+others); see comments inline.
// =============================================================================

var lg2Excluded: [String] = [
    "deps/llhttp/CMakeLists.txt",
    "deps/llhttp/LICENSE-MIT",
    "deps/pcre/CMakeLists.txt",
    "deps/pcre/COPYING",
    "deps/pcre/LICENCE",
    "deps/pcre/cmake",
    "deps/pcre/config.h.in",
    "deps/xdiff/CMakeLists.txt",
    "deps/zlib/CMakeLists.txt",
    "deps/zlib/LICENSE",
    "deps/ntlmclient/CMakeLists.txt",
    "src/libgit2/CMakeLists.txt",
    "src/libgit2/experimental.h.in",
    "src/libgit2/git2.rc",
    "src/libgit2/config.cmake.in",
    "src/util/CMakeLists.txt",
    "src/util/git2_features.h.in",

    "src/util/hash/win32.c",
    "src/util/hash/win32.h",
    "src/util/win32",

    "src/util/hash/mbedtls.c",
    "src/util/hash/mbedtls.h",
    "deps/ntlmclient/crypt_mbedtls.c",
    "deps/ntlmclient/crypt_mbedtls.h",
    "deps/ntlmclient/crypt_builtin_md4.c",

    "src/util/hash/openssl.c",
    "src/util/hash/openssl.h",

    "deps/ntlmclient/unicode_iconv.c",
    "deps/ntlmclient/unicode_iconv.h",
]

var lg2C: [CSetting] = [
    .headerSearchPath("deps/llhttp"),
    .headerSearchPath("deps/pcre"),
    .headerSearchPath("deps/xdiff"),
    .headerSearchPath("deps/zlib"),
    .headerSearchPath("deps/ntlmclient"),
    .headerSearchPath("src/libgit2"),
    .headerSearchPath("src/util"),

    .define("LIBGIT2_NO_FEATURES_H"),
    .define("GIT_THREADS", to: "1"),
    .define("GIT_THREADS_PTHREADS", to: "1"),
    .define("GIT_ARCH_64", to: "1"),

    .define("GIT_REGEX_BUILTIN", to: "1"),
    .define("SUPPORT_PCRE8", to: "1"),
    .define("HAVE_STDINT_H", to: "1"),
    .define("HAVE_INTTYPES_H", to: "1"),
    .define("HAVE_MEMMOVE", to: "1"),
    .define("HAVE_STRERROR", to: "1"),
    .define("LINK_SIZE", to: "2"),
    .define("PARENS_NEST_LIMIT", to: "250"),
    .define("MATCH_LIMIT", to: "10000000"),
    .define("MATCH_LIMIT_RECURSION", to: "10000000"),
    .define("NEWLINE", to: "10"),
    .define("NO_RECURSE", to: "1"),
    .define("POSIX_MALLOC_THRESHOLD", to: "10"),
    .define("BSR_ANYCRLF", to: "0"),
    .define("MAX_NAME_SIZE", to: "32"),
    .define("MAX_NAME_COUNT", to: "10000"),

    .define("GIT_SSH", to: "1", .when(platforms: [.macOS, .iOS, .linux, .android])),
    .define("GIT_SSH_EXEC", to: "1", .when(platforms: [.macOS, .iOS, .linux, .android])),

    .define("GIT_HTTPS", to: "1"),
    .define("GIT_HTTPPARSER_BUILTIN", to: "1"),

    .define("GIT_NSEC", to: "1"),

    .define("GIT_AUTH_NTLM", to: "1"),

    .define("GIT_COMPRESSION_BUILTIN", to: "1"),
]

var lg2Link: [LinkerSetting] = []

#if os(macOS)
    lg2Excluded += [
        "src/util/hash/builtin.c",
        "src/util/hash/builtin.h",
        "src/util/hash/collisiondetect.c",
        "src/util/hash/collisiondetect.h",
        "src/util/hash/rfc6234",
        "src/util/hash/sha1dc",
        "deps/ntlmclient/crypt_openssl.c",
        "deps/ntlmclient/crypt_openssl.h",
    ]
    lg2C += [
        .define("GIT_QSORT_BSD"),
        .define("GIT_HTTPS_SECURETRANSPORT", to: "1"),
        .define("GIT_IO_POLL", to: "1"),
        .define("GIT_SHA1_COMMON_CRYPTO", to: "1"),
        .define("GIT_SHA256_COMMON_CRYPTO", to: "1"),
        .define("GIT_AUTH_NTLM_BUILTIN", to: "1"),
        .define("NTLM_STATIC", to: "1"),
        .define("UNICODE_BUILTIN", to: "1"),
        .define("CRYPT_COMMONCRYPTO"),
        .define("GIT_FUTIMENS", to: "1"),
        .define("GIT_NSEC_MTIMESPEC", to: "1"),
        .define("GIT_I18N", to: "1"),
        .define("GIT_I18N_ICONV", to: "1"),
        .define("GIT_NO_PROCESS_SPAWN", .when(platforms: [.tvOS, .watchOS])),
    ]
    lg2Link += [
        .linkedLibrary("iconv"),
    ]
#elseif os(Windows)
    lg2Excluded += [
        "src/util/hash/common_crypto.c",
        "src/util/hash/common_crypto.h",
        "deps/ntlmclient/crypt_commoncrypto.c",
        "deps/ntlmclient/crypt_commoncrypto.h",

        "src/util/hash/builtin.c",
        "src/util/hash/builtin.h",
        "src/util/hash/collisiondetect.c",
        "src/util/hash/collisiondetect.h",
        "src/util/hash/rfc6234",
        "src/util/hash/sha1dc",

        "deps/ntlmclient",

        "src/util/unix",

        "src/util/win32/precompiled.c",
    ]
    // SwiftPM has no "unexclude" -- re-add the Windows files dropped above.
    let windowsReinclude: Set<String> = [
        "src/util/hash/win32.c",
        "src/util/hash/win32.h",
        "src/util/win32",
    ]
    lg2Excluded.removeAll(where: { windowsReinclude.contains($0) })

    lg2C += [
        .define("_WIN32_WINNT", to: "0x0A00"),
        .define("WIN32_LEAN_AND_MEAN"),
        .define("NOMINMAX"),
        .define("_CRT_SECURE_NO_WARNINGS"),
        .define("_CRT_NONSTDC_NO_WARNINGS"),
        .define("STRSAFE_NO_DEPRECATE"),

        .define("GIT_THREADS_WIN32", to: "1"),
        .define("GIT_QSORT_MSC", to: "1"),
        .define("GIT_HTTPS_SCHANNEL", to: "1"),
        .define("GIT_SHA1_WIN32", to: "1"),
        .define("GIT_SHA256_WIN32", to: "1"),
        .define("GIT_AUTH_NTLM_SSPI", to: "1"),
        .define("GIT_AUTH_NEGOTIATE", to: "1"),
        .define("GIT_AUTH_NEGOTIATE_SSPI", to: "1"),
        .define("GIT_NSEC_WIN32", to: "1"),
        .define("GIT_IO_WSAPOLL", to: "1"),
    ]
    lg2Link += [
        .linkedLibrary("advapi32"),
        .linkedLibrary("bcrypt"),
        .linkedLibrary("crypt32"),
        .linkedLibrary("ole32"),
        .linkedLibrary("rpcrt4"),
        .linkedLibrary("secur32"),
        .linkedLibrary("ws2_32"),
    ]
#else
    lg2Excluded += [
        "src/util/hash/common_crypto.c",
        "src/util/hash/common_crypto.h",
        "deps/ntlmclient/crypt_commoncrypto.c",
        "deps/ntlmclient/crypt_commoncrypto.h",
    ]
    lg2C += [
        .define("_GNU_SOURCE"),
        .define("GIT_QSORT_GNU", .when(platforms: [.linux])),
        .define("GIT_IO_POLL", to: "1"),
        .define("GIT_HTTPS_OPENSSL_DYNAMIC", to: "1"),
        .define("GIT_SHA1_BUILTIN", to: "1"),
        .define("GIT_SHA256_BUILTIN", to: "1"),
        .define("SHA1DC_NO_STANDARD_INCLUDES", to: "1"),
        .define("SHA1DC_CUSTOM_INCLUDE_SHA1_C", to: "\"git2_util.h\""),
        .define("SHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C", to: "\"git2_util.h\""),
        .headerSearchPath("src/util/hash/sha1dc"),
        .headerSearchPath("src/util/hash/rfc6234"),
        .define("GIT_AUTH_NTLM_BUILTIN", to: "1"),
        .define("NTLM_STATIC", to: "1"),
        .define("UNICODE_BUILTIN", to: "1"),
        .define("CRYPT_OPENSSL"),
        .define("CRYPT_OPENSSL_DYNAMIC"),
        .define("OPENSSL_API_COMPAT", to: "0x10100000L"),
        .define("GIT_FUTIMENS", to: "1"),
        .define("GIT_NSEC_MTIM", to: "1"),
        .define("GIT_RAND_GETENTROPY", to: "1", .when(platforms: [.linux])),
        .define("GIT_RAND_GETLOADAVG", to: "1", .when(platforms: [.linux])),
    ]
    lg2Link += [
        .linkedLibrary("z"),
        .linkedLibrary("dl"),
        .linkedLibrary("pthread"),
    ]
#endif

// =============================================================================
// Package
// =============================================================================

let package = Package(
    name: "Giteax",
    platforms: [
        .macOS(.v14),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Giteax", targets: ["Giteax"]),
        .executable(name: "giteax-serve", targets: ["GiteaxServer"]),
    ],
    dependencies: [
        // hggz Swift-on-Windows substrate (Phase F pins, public)
        .package(url: "https://github.com/hggz/vapor.git",
                 revision: "d3fa2d09"),
        .package(url: "https://github.com/hggz/swift-nio.git",
                 revision: "7c9c6861"),
        .package(url: "https://github.com/hggz/swift-nio-extras.git",
                 revision: "076c9b49"),
        .package(url: "https://github.com/hggz/async-http-client.git",
                 revision: "eaaf46a"),
        .package(url: "https://github.com/hggz/swift-nio-ssl.git",
                 revision: "7f9efd5"),
        .package(url: "https://github.com/hggz/websocket-kit.git",
                 revision: "ddfba8c"),

        // NOTE: libgit2 and SwiftGitX are vendored as local targets below
        // (no `.package(...)` lines, no SSH URLs). The NIOSSH listener is
        // dropped from this vendored snapshot (see Sources/Giteax/Giteax.swift).
    ],
    targets: [
        // Vendored libgit2 (hggz/libgit2:windows-schannel arm)
        .target(
            name: "libgit2",
            path: "Sources/libgit2",
            exclude: lg2Excluded,
            sources: [
                "deps/llhttp",
                "deps/pcre",
                "deps/xdiff",
                "deps/zlib",
                "deps/ntlmclient",
                "src/libgit2",
                "src/util",
            ],
            publicHeadersPath: "include",
            cSettings: lg2C,
            linkerSettings: lg2Link
        ),

        // Vendored SwiftGitX (Swift wrapper around libgit2)
        .target(
            name: "SwiftGitX",
            dependencies: ["libgit2"],
            path: "Sources/SwiftGitX"
        ),

        // Vendored SQLite amalgamation (FTS5 code search)
        .target(
            name: "Csqlite3",
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_JSON1"),
                .define("SQLITE_ENABLE_RTREE"),
                .define("SQLITE_THREADSAFE", to: "2"),
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
                .define("SQLITE_OMIT_DEPRECATED"),
                .define("SQLITE_USE_URI", to: "1"),
                .unsafeFlags(["-w"]),
            ]
        ),

        // Giteax library + thin server binary
        .target(
            name: "Giteax",
            dependencies: [
                .product(name: "Vapor",           package: "vapor"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                "SwiftGitX",
                "Csqlite3",
            ]
        ),
        .executableTarget(
            name: "GiteaxServer",
            dependencies: [
                "Giteax",
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
    ]
)
