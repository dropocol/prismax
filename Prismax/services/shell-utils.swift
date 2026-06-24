import Foundation

/// Quotes a string for safe inclusion in a shell command. Wraps in single
/// quotes and escapes any embedded single quotes. Shared by the backup service,
/// SchemaService, and command-building helpers.
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
