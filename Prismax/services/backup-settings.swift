import Foundation

/// Resolves where a project's environment backups are stored on disk.
///
/// Backup location is configurable with a clear precedence:
/// 1. **Per-project override** (`Project.backupDirectoryOverride`)
/// 2. **App-wide global default** (Settings → Backups; this enum's
///    `globalDefaultURL`)
/// 3. **Built-in default** — `~/Library/Application Support/PrismaX/backups`
///
/// The built-in default nests by project/environment UUIDs (opaque but
/// collision-free). A configured location (global or override) instead nests by
/// human-readable names — `<location>/<project name>/<environment name>/` — so
/// the folder is easy to browse in Finder and per-environment separation is
/// preserved without leaking UUIDs.
///
/// PrismaX is **not** sandboxed (ad-hoc signed, no app-sandbox entitlement), so
/// plain absolute paths are used — no security-scoped bookmarks required.
enum BackupSettings {
    /// UserDefaults key for the app-wide default backup folder path.
    static let globalLocationKey = "backupLocation"

    // MARK: Global default

    /// The configured app-wide default backup folder, or nil if unset (in which
    /// case the built-in default is used).
    static func globalDefaultURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: globalLocationKey),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Sets or clears the app-wide default backup folder.
    static func setGlobalDefault(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: globalLocationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: globalLocationKey)
        }
    }

    // MARK: Built-in default

    /// The built-in fallback location: `~/Library/Application Support/PrismaX/backups`.
    static var builtInDefaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PrismaX", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
    }

    // MARK: Resolution

    /// The effective backup root for a project — its override if set, else the
    /// global default, else the built-in default.
    static func effectiveRoot(for project: Project) -> URL {
        if let override = project.backupDirectoryOverride, !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let global = globalDefaultURL() {
            return global
        }
        return builtInDefaultRoot
    }

    /// Resolves the directory a specific (project, environment) pair stores
    /// backups in. Applies the precedence above, then nests under it.
    ///
    /// When using a configured location, nesting is `<root>/<project>/<env>/`
    /// (human-readable). When using the built-in default, nesting is
    /// `<root>/<projectID>/<envID>/` (matches pre-existing on-disk layout).
    static func resolvedURL(project: Project, environment: EnvProfile) -> URL {
        let root = effectiveRoot(for: project)
        let usingBuiltIn = project.backupDirectoryOverride == nil && globalDefaultURL() == nil
        if usingBuiltIn {
            return root
                .appendingPathComponent(project.id.uuidString, isDirectory: true)
                .appendingPathComponent(environment.id.uuidString, isDirectory: true)
        }
        return root
            .appendingPathComponent(safeFolderName(project.name), isDirectory: true)
            .appendingPathComponent(safeFolderName(environment.name), isDirectory: true)
    }

    /// Sanitizes a display name for use as a folder component, replacing
    /// path/separator characters so it can't escape the chosen root.
    static func safeFolderName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled"
            : cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
