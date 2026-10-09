import Foundation

/// Which model a session is using. Hook payloads do not carry it, but every one has `transcript_path`,
/// and the transcript's assistant records do.
public enum ModelName {
    private static let families: Set<String> = ["opus", "sonnet", "haiku", "fable"]

    /// "claude-sonnet-5-5" -> "Sonnet 5.5", "claude-opus-4-1-20250805" -> "Opus 4.1",
    /// "claude-3-5-sonnet-20241022" -> "Sonnet 3.5", "claude-opus-5-5[1m]" -> "Opus 5.5 (1M)".
    /// Anything it cannot place is returned as given.
    public static func display(_ id: String) -> String {
        var s = id.lowercased()
        var context = ""
        if let open = s.firstIndex(of: "["), s.hasSuffix("]") {
            context = " (\(s[s.index(after: open)..<s.index(before: s.endIndex)].uppercased()))"
            s = String(s[..<open])
        }
        // Drop provider prefixes ("us.anthropic.") and suffixes ("-v1:0").
        if let r = s.range(of: "claude-") { s = String(s[r.upperBound...]) }
        let tokens = s.split(separator: "-").map(String.init).filter { token in
            !(token.count == 8 && token.allSatisfy(\.isNumber)) && !token.contains(":")
        }
        guard let family = tokens.first(where: { families.contains($0) })
                ?? tokens.first(where: { $0.allSatisfy(\.isLetter) }) else { return id }
        let version = tokens.filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return (version.isEmpty ? name : "\(name) \(version)") + context
    }
}

public enum TranscriptModel {
    /// Only the end of the file is read: transcripts get large and the newest record is what counts.
    static let tailBytes = 256 * 1024

    /// The model of the newest assistant record that names one, or nil if the file is missing or has none.
    public static func latest(inFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        return latest(inText: text)
    }

    static func latest(inText text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""model"\s*:\s*"([^"]+)""#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range).reversed() {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let id = String(text[r])
            // Synthetic records (API errors, interrupts) are not a model the user picked.
            if !id.hasPrefix("<") { return id }
        }
        return nil
    }
}
