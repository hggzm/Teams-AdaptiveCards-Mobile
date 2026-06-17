//
//  IntegerBridging.swift
//  SwiftGitX
//
//  Added by hggz/SwiftGitX:windows-msvc-enum-bridging
//
//  Clang imports libgit2 C enums with different raw types on different
//  platforms: UInt32 on Apple/Linux Clang, Int32 on Windows MSVC Clang.
//  These helpers normalize between Swift integer types using truncating
//  conversions that work on any BinaryInteger and never trap. Safe for
//  the flag / bitmask / enum-tag usage that SwiftGitX needs.
//

@inline(__always)
internal func _u32<I: BinaryInteger>(_ v: I) -> UInt32 {
    UInt32(truncatingIfNeeded: v)
}

@inline(__always)
internal func _i32<I: BinaryInteger>(_ v: I) -> Int32 {
    Int32(truncatingIfNeeded: v)
}
