import Foundation

struct TechnicalTextPreview: Equatable {
    let text: String
    let lineCount: Int
    let omittedBytes: Int

    static func make(
        source: String,
        byteLimit: Int = 24_000,
        lineLimit: Int = 12
    ) -> TechnicalTextPreview {
        let bytes = source.utf8
        let boundedByteLimit = max(1, byteLimit)
        let tail = bytes.count > boundedByteLimit
            ? String(decoding: bytes.suffix(boundedByteLimit), as: UTF8.self)
            : source
        let lines = tail.components(separatedBy: .newlines)
        let visible = Array(lines.suffix(max(1, lineLimit)))
        let omittedBytes = max(0, bytes.count - tail.utf8.count)
        let omitted = omittedBytes > 0 || lines.count > visible.count
        let renderedLines = (omitted ? ["... earlier output omitted ..."] : []) + visible
        return TechnicalTextPreview(
            text: renderedLines.joined(separator: "\n"),
            lineCount: max(1, renderedLines.count),
            omittedBytes: omittedBytes
        )
    }
}
