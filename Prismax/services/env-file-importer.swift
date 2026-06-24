import Foundation

/// Parses a pasted/selected `.env` file body into key/value pairs.
/// Values are NOT stored here — the caller persists values into the Keychain.
enum EnvFileImporter {

    struct Pair {
        let key: String
        let value: String
    }

    /// Parses KEY=VALUE lines. Supports `#` comments, blank lines, optional
    /// surrounding quotes, and `export KEY=...` syntax.
    static func parse(_ text: String) -> [Pair] {
        var pairs: [Pair] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            var working = line
            if working.hasPrefix("export ") { working = String(working.dropFirst("export ".count)) }

            guard let eq = working.firstIndex(of: "=") else { continue }
            let key = String(working[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(working[working.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            // Strip matching surrounding quotes.
            value = stripQuotes(value)

            if !key.isEmpty {
                pairs.append(Pair(key: key, value: value))
            }
        }
        return pairs
    }

    private static func stripQuotes(_ value: String) -> String {
        if value.count >= 2 {
            let first = value.first
            let last = value.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                return String(value.dropFirst().dropLast())
            }
        }
        return value
    }
}
