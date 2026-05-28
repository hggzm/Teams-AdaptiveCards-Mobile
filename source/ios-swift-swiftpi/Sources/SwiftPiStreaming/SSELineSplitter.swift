// SSELineSplitter — byte-state machine that yields complete lines from a
// byte stream that may arrive in arbitrary chunks.
//
// Why a separate splitter:
//   1. Stripping a UTF-8 BOM once at the very beginning.
//   2. Handling all three SSE-spec line terminators (LF, CRLF, lone CR)
//      including a CR at the very end of a chunk (where we don't yet
//      know if the next chunk starts with LF).
//   3. Buffering partial UTF-8 multibyte sequences across chunk
//      boundaries (we keep raw bytes until we have a complete line,
//      then UTF-8-decode the whole line at once).

import Foundation

/// A byte-level line splitter for SSE. Feed bytes incrementally with
/// `feed(_:)`; the returned `[String]` is the set of *complete* lines
/// produced by that chunk. Trailing partial data stays buffered.
public struct SSELineSplitter: Sendable {
    // SSE-spec byte values we care about.
    @usableFromInline static let lf: UInt8 = 0x0A
    @usableFromInline static let cr: UInt8 = 0x0D
    @usableFromInline static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Pending bytes that haven't yet formed a complete line.
    private var pending: [UInt8] = []

    /// If `true`, the previous chunk ended with a lone CR. The next
    /// incoming LF (if any) is part of that CRLF terminator and should
    /// be consumed silently; any other byte signals the lone CR was the
    /// terminator and the new byte belongs to the next line.
    private var awaitingLFAfterCR: Bool = false

    /// Whether we have already considered (and possibly stripped) a
    /// UTF-8 BOM at the very start of the stream.
    private var bomChecked: Bool = false

    public init() {}

    // MARK: - Feeding bytes

    /// Feed a chunk of bytes. Returns every line that was completed by
    /// this chunk, in order. Partial trailing data is buffered for the
    /// next call.
    public mutating func feed(_ chunk: [UInt8]) -> [String] {
        guard !chunk.isEmpty else { return [] }

        var lines: [String] = []
        var index = chunk.startIndex
        let end = chunk.endIndex

        // The very first byte that we ever observe potentially starts a
        // UTF-8 BOM. We strip the BOM only if it appears at offset 0 of
        // the stream as a whole; mid-stream `EF BB BF` runs are left
        // alone because they're legal UTF-8 (a zero-width no-break space
        // code point) and not a stream marker.
        if !bomChecked {
            if pending.isEmpty {
                // Look at chunk[0..2] if available; otherwise wait for
                // more bytes by buffering whatever we have.
                let available = min(SSELineSplitter.bom.count, end - index)
                if available < SSELineSplitter.bom.count {
                    pending.append(contentsOf: chunk[index..<end])
                    return lines
                }
                if Array(chunk[index..<(index + SSELineSplitter.bom.count)]) == SSELineSplitter.bom {
                    index += SSELineSplitter.bom.count
                }
                bomChecked = true
            } else if pending.count + (end - index) >= SSELineSplitter.bom.count {
                // We have some pending bytes from a tiny earlier chunk;
                // check the combined prefix once we have enough bytes.
                var combined = pending
                let needed = SSELineSplitter.bom.count - combined.count
                combined.append(contentsOf: chunk[index..<(index + needed)])
                if combined == SSELineSplitter.bom {
                    pending.removeAll()
                    index += needed
                }
                bomChecked = true
            }
        }

        while index < end {
            let byte = chunk[index]

            // If we were holding a CR from a previous byte, the next
            // byte tells us whether it was CRLF (consume the LF) or a
            // lone CR (already dispatched; this byte starts a new line).
            if awaitingLFAfterCR {
                awaitingLFAfterCR = false
                if byte == SSELineSplitter.lf {
                    index += 1
                    continue
                }
                // Else fall through and let the normal scan handle this
                // byte; the lone CR has already been treated as the line
                // terminator that closed `pending`.
            }

            if byte == SSELineSplitter.lf {
                lines.append(decodeAndConsumePending())
                index += 1
                continue
            }

            if byte == SSELineSplitter.cr {
                // CR alone closes a line; if it's followed by LF in the
                // same chunk we'll skip that LF. If we don't have a next
                // byte yet (end-of-chunk), set the flag and wait.
                lines.append(decodeAndConsumePending())
                index += 1
                if index < end {
                    if chunk[index] == SSELineSplitter.lf {
                        index += 1
                    }
                } else {
                    awaitingLFAfterCR = true
                }
                continue
            }

            pending.append(byte)
            index += 1
        }

        return lines
    }

    /// Convenience for callers holding `Data`.
    public mutating func feed(_ chunk: Data) -> [String] {
        feed(Array(chunk))
    }

    /// Drain the splitter at end-of-stream. Returns any final partial
    /// line that wasn't followed by a terminator.
    public mutating func finish() -> [String] {
        // If we were awaiting an LF after a CR, that CR was the
        // terminator — nothing left to do for that case (pending was
        // already drained when we saw the CR).
        awaitingLFAfterCR = false
        guard !pending.isEmpty else { return [] }
        return [decodeAndConsumePending()]
    }

    // MARK: - Internal helpers

    /// UTF-8-decode the currently-buffered bytes and reset the buffer.
    /// Invalid byte sequences are replaced with the Unicode replacement
    /// character; we deliberately do NOT throw here because the SSE
    /// spec says lone invalid bytes should not abort the stream.
    private mutating func decodeAndConsumePending() -> String {
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return line
    }
}
