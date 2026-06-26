import Foundation
import AppKit

/// On-disk format for a backup file.
///
/// - `compressed`: Postgres custom format (`pg_dump -F c`, `.dump`) — compact,
///   supports selective/parallel restore via `pg_restore`. Default.
/// - `plainSQL`: Portable, human/diff-readable SQL text (`pg_dump` with no
///   `-F`, `.sql`) restored via `psql -f`. Useful when you want to inspect or
///   edit the dump before restoring.
enum BackupFormat: String, Codable, CaseIterable, Identifiable {
    case compressed, plainSQL
    var id: String { rawValue }

    var label: String {
        switch self {
        case .compressed: "Compressed (.dump)"
        case .plainSQL: "Plain SQL (.sql)"
        }
    }
}

/// Runs database backups and restores. Detects the DB provider from the
/// `DATABASE_URL` scheme and shells out to `pg_dump` / `mysqldump` / `sqlite3`.
enum BackupService {

    enum Provider: String {
        case postgres, mysql, sqlite

        init?(urlScheme: String) {
            switch urlScheme.lowercased() {
            case "postgresql", "postgres": self = .postgres
            case "mysql": self = .mysql
            case "file", "sqlite": self = .sqlite
            default: return nil
            }
        }

        var label: String {
            switch self {
            case .postgres: "PostgreSQL"
            case .mysql: "MySQL"
            case .sqlite: "SQLite"
            }
        }

        var symbol: String {
            switch self {
            case .postgres: "elephant" // SF Symbol fallback handled in UI
            case .mysql: "cylinder"
            case .sqlite: "internaldrive"
            }
        }
    }

    enum BackupError: Error, LocalizedError {
        case unsupportedProvider(String)
        case missingURL
        case restoreFailed(String)
        case toolMissing(provider: Provider, tool: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedProvider(let s):
                return "Unsupported database provider in URL scheme: \(s)"
            case .missingURL:
                return "No DATABASE_URL is set for this environment."
            case .restoreFailed(let s):
                return "Restore failed: \(s)"
            case .toolMissing(let provider, let tool):
                // Actionable guidance: explain WHAT'S missing and HOW to install
                // it for this provider, so users aren't left decoding exit 127.
                switch provider {
                case .postgres:
                    return [
                        "\"\(tool)\" was not found. Install the PostgreSQL client tools to back up / restore.",
                        "",
                        "• Homebrew:  brew install libpq   (or postgresql@17)",
                        "• Postgres.app:  https://postgresapp.com",
                        "• EnterpriseDB:  https://www.enterprisedb.com/downloads",
                        "",
                        "Then relaunch PrismaX.",
                    ].joined(separator: "\n")
                case .mysql:
                    return [
                        "\"\(tool)\" was not found. Install the MySQL client tools.",
                        "",
                        "• Homebrew:  brew install mysql-client",
                        "• MySQL.com:  https://dev.mysql.com/downloads",
                        "",
                        "Then relaunch PrismaX.",
                    ].joined(separator: "\n")
                case .sqlite:
                    return "\"\(tool)\" was not found. sqlite3 ships with macOS — it should be at /usr/bin/sqlite3. If missing, reinstall Command Line Tools: xcode-select --install."
                }
            }
        }
    }

    // MARK: Backup

    /// Creates a timestamped backup file in `directory`, named with
    /// `environmentName` and the detected provider.
    ///
    /// Callers resolve `directory` via `BackupSettings.resolvedURL(...)` on the
    /// main actor (it reads SwiftData models) and pass the resulting Sendable
    /// URL here — keeping this method decoupled from SwiftData and safe to call
    /// from a detached Task.
    ///
    /// - Parameters:
    ///   - format: On-disk format (compressed `.dump` vs plain `.sql`).
    ///     Only Postgres distinguishes the two; MySQL/SQLite always emit SQL.
    ///   - schemaOnly: When true (Postgres only), restricts the dump to the
    ///     `public` schema and omits Prisma's migration-history table
    ///     (`_prisma_migrations`), yielding a data-only snapshot that's safe to
    ///     restore across environments without clobbering migration state.
    static func backup(
        databaseURL: String,
        environmentName: String,
        directory: URL,
        format: BackupFormat = .compressed,
        schemaOnly: Bool = false
    ) async throws -> BackupResult {
        guard let url = URL(string: databaseURL), let scheme = url.scheme,
              let provider = Provider(urlScheme: scheme) else {
            throw BackupError.unsupportedProvider(URL(string: databaseURL)?.scheme ?? "(none)")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = Self.timestamp()
        // Embed the provider, scope, and format in the filename so backups can be
        // labeled accurately when listed later (the extension alone is ambiguous:
        // mysql and sqlite both use .sql). The scope tag (-data / -full) makes a
        // portable data snapshot visually distinct from a full clone.
        let scopeTag = schemaOnly ? "data" : "full"
        let fileURL = directory.appendingPathComponent("\(environmentName)-\(provider.rawValue)-\(scopeTag)-\(stamp)\(BackupService.Provider.fileExtension(for: provider, format: format))")

        let command = try backupCommand(provider: provider, url: url, outputFile: fileURL, format: format, schemaOnly: schemaOnly)
        let output = try await ShellRunner.run(command: command, onToolMissing: raiseToolMissing)

        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? Int) ?? 0

        return BackupResult(
            fileURL: fileURL,
            provider: provider,
            sizeBytes: size,
            output: output,
            createdAt: Date()
        )
    }

    // MARK: Restore

    /// Restores a backup into the database at `databaseURL`. The restore method
    /// is chosen from the backup's on-disk format: compressed `.dump` uses
    /// `pg_restore`, plain `.sql` uses `psql -f` (and likewise `mysql`/`sqlite3`
    /// for those providers).
    static func restore(databaseURL: String, from fileURL: URL) async throws -> String {
        guard let url = URL(string: databaseURL), let scheme = url.scheme,
              let provider = Provider(urlScheme: scheme) else {
            throw BackupError.unsupportedProvider(URL(string: databaseURL)?.scheme ?? "(none)")
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BackupError.restoreFailed("Backup file not found.")
        }
        let format = BackupFormat.format(for: fileURL, provider: provider)
        let command = try restoreCommand(provider: provider, url: url, inputFile: fileURL, format: format)
        return try await ShellRunner.run(command: command, onToolMissing: raiseToolMissing)
    }

    /// Restores a backup into a *different* environment's database — e.g. copy
    /// production data into staging. The backup file stays where it is; only the
    /// target connection changes. Useful for seeding a lower environment from a
    /// snapshot taken elsewhere.
    static func restoreCrossEnvironment(from fileURL: URL, toDatabaseURL targetURL: String) async throws -> String {
        guard let url = URL(string: targetURL), let scheme = url.scheme,
              let provider = Provider(urlScheme: scheme) else {
            throw BackupError.unsupportedProvider(URL(string: targetURL)?.scheme ?? "(none)")
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BackupError.restoreFailed("Backup file not found.")
        }
        let format = BackupFormat.format(for: fileURL, provider: provider)
        let command = try restoreCommand(provider: provider, url: url, inputFile: fileURL, format: format)
        return try await ShellRunner.run(command: command, onToolMissing: raiseToolMissing)
    }

    // MARK: Listing

    /// Lists existing backups for a (project, environment), read from that
    /// environment's resolved backup directory.
    static func backups(project: Project, environment: EnvProfile) -> [BackupResult] {
        let dir = BackupSettings.resolvedURL(project: project, environment: environment)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]) else {
            return []
        }
        return entries
            .filter { Self.isBackupFile($0) }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                let provider = Provider.provider(for: url)
                return BackupResult(
                    fileURL: url,
                    provider: provider,
                    sizeBytes: values?.fileSize ?? 0,
                    output: "",
                    createdAt: values?.creationDate ?? Date()
                )
            }
            .sorted(by: { $0.createdAt > $1.createdAt })
    }

    /// Whether a directory entry is a recognized backup file. Accepts proper
    /// extensions (`.dump`/`.sql`) and is tolerant of an early bug that wrote
    /// extensions without a dot (`…stampdump`/`…stampsql`), so legacy backups
    /// still appear in history and remain restorable.
    private static func isBackupFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "sql" || ext == "dump" { return true }
        let name = url.lastPathComponent
        return name.hasSuffix("dump") || name.hasSuffix("sql")
    }

    static func delete(fileURL: URL) throws {
        try FileManager.default.removeItem(at: fileURL)
    }

    static func reveal(fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    /// Reveals a backup directory in Finder. If the directory doesn't exist yet
    /// (no backups taken), reveals its parent so the user still lands somewhere
    /// useful; creates the directory first so Finder shows the intended folder.
    static func revealDirectory(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // Best effort — don't fail the reveal if creation is blocked.
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let target = fm.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.open(target)
    }

    // MARK: Paths

    /// The resolved backup directory for a (project, environment). Delegates to
    /// `BackupSettings` for the global-default / per-project-override precedence.
    static func backupDirectory(project: Project, environment: EnvProfile) -> URL {
        BackupSettings.resolvedURL(project: project, environment: environment)
    }

    // MARK: Command building

    private static func backupCommand(provider: Provider, url: URL, outputFile: URL, format: BackupFormat, schemaOnly: Bool) throws -> ShellCommand {
        // Postgres-only refinements applied when backing up just the public
        // schema (skip Prisma's migration history so the snapshot is portable).
        let schemaArgs: String = schemaOnly ? " --schema=public --exclude-table-data=_prisma_migrations" : ""
        switch provider {
        case .postgres:
            // Connection string form (works with pg_dump 16+). Password stays in
            // the URL (already resolved from env file/Keychain) rather than on
            // the command line via PGPASSWORD — either is fine, this is simpler.
            switch format {
            case .compressed:
                return ShellCommand(commandLine: #"pg_dump "\#(url.absoluteString)" -F c\#(schemaArgs) -f "\#(outputFile.path)""#)
            case .plainSQL:
                return ShellCommand(commandLine: #"pg_dump "\#(url.absoluteString)"\#(schemaArgs) -f "\#(outputFile.path)""#)
            }
        case .mysql:
            guard let host = url.host, let port = url.port else { throw BackupError.missingURL }
            // Credentials are passed via MYSQL_PWD in the process environment,
            // never on the command line.
            var cmd = ShellCommand(commandLine: #"mysqldump -h \#(shellQuote(host)) -P \#(port) -u \#(shellQuote(url.user ?? "root")) \#(shellQuote(url.lastPathComponent)) > "\#(outputFile.path)""#)
            if let pwd = url.password { cmd.extraEnvironment["MYSQL_PWD"] = pwd }
            return cmd
        case .sqlite:
            return ShellCommand(commandLine: #"sqlite3 "\#(url.path)" .dump > "\#(outputFile.path)""#)
        }
    }

    private static func restoreCommand(provider: Provider, url: URL, inputFile: URL, format: BackupFormat) throws -> ShellCommand {
        switch provider {
        case .postgres:
            switch format {
            case .compressed:
                return ShellCommand(commandLine: #"pg_restore --clean --if-exists -d "\#(url.absoluteString)" "\#(inputFile.path)""#)
            case .plainSQL:
                // psql continues past errors (ON_ERROR_STOP=0) so version-skew
                // between dump source and target (e.g. a SET for a parameter
                // the target doesn't know) doesn't abort the whole import.
                return ShellCommand(commandLine: #"psql -v ON_ERROR_STOP=0 -d "\#(url.absoluteString)" -f "\#(inputFile.path)""#)
            }
        case .mysql:
            guard let host = url.host, let port = url.port else { throw BackupError.missingURL }
            var cmd = ShellCommand(commandLine: #"mysql -h \#(shellQuote(host)) -P \#(port) -u \#(shellQuote(url.user ?? "root")) \#(shellQuote(url.lastPathComponent)) < "\#(inputFile.path)""#)
            if let pwd = url.password { cmd.extraEnvironment["MYSQL_PWD"] = pwd }
            return cmd
        case .sqlite:
            return ShellCommand(commandLine: #"sqlite3 "\#(url.path)" < "\#(inputFile.path)""#)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }

    /// Infers the DB provider from a CLI tool name, for `toolMissing` errors.
    private static func provider(forTool tool: String) -> Provider {
        let t = tool.lowercased()
        if t.hasPrefix("pg") || t == "psql" { return .postgres }
        if t.hasPrefix("mysql") { return .mysql }
        if t.hasPrefix("sqlite") { return .sqlite }
        return .postgres // best-effort default
    }

    /// Callback for `ShellRunner.run`: maps a missing tool name to the
    /// domain-specific `BackupError.toolMissing` with install hints.
    private static func raiseToolMissing(_ tool: String) throws {
        throw BackupError.toolMissing(provider: provider(forTool: tool), tool: tool)
    }
}

// MARK: - Supporting types

struct BackupResult: Identifiable {
    var id: URL { fileURL }
    let fileURL: URL
    let provider: BackupService.Provider
    var sizeBytes: Int
    var output: String
    var createdAt: Date
}

extension BackupService.Provider {
    /// File extension (with dot) for a fresh backup of this provider in the
    /// given format. Postgres distinguishes compressed (`.dump`) from plain
    /// (`.sql`); the others always emit SQL text. Includes the leading dot so it
    /// can be concatenated into a filename directly.
    static func fileExtension(for provider: BackupService.Provider, format: BackupFormat) -> String {
        switch provider {
        case .postgres: format == .compressed ? ".dump" : ".sql"
        case .mysql, .sqlite: ".sql"
        }
    }

    /// Derives the provider from a backup filename, falling back to the
    /// extension. New backups embed the provider in the name
    /// (`{env}-{provider}-{stamp}`); older ones without it are inferred:
    /// `.dump` → postgres, `.sql` → mysql (the more common of the two; sqlite
    /// dumps are rare and we can't tell from the extension alone).
    ///
    /// Tolerant of an early bug that wrote extensions without a dot
    /// (`…stampdump`): those parse by the embedded provider token, and a name
    /// ending in `dump`/`sql` still resolves correctly.
    static func provider(for url: URL) -> BackupService.Provider {
        let name = url.deletingPathExtension().lastPathComponent
        for part in name.split(separator: "-") {
            if let provider = BackupService.Provider(rawValue: String(part)) {
                return provider
            }
        }
        if url.pathExtension == "dump" { return .postgres }
        // Legacy dotless names like "...2026-06-25_153910dump".
        if name.hasSuffix("dump") { return .postgres }
        return .mysql
    }
}

extension BackupFormat {
    /// Infers the on-disk format of an existing backup file for a given
    /// provider, so restore can pick the right tool (`pg_restore` vs `psql`).
    /// Postgres `.dump` → compressed; everything else (`.sql`) → plainSQL.
    ///
    /// Tolerant of an early bug that wrote extensions without a dot
    /// (`…stampdump`): such names still resolve to compressed for Postgres.
    static func format(for url: URL, provider: BackupService.Provider) -> BackupFormat {
        guard provider == .postgres else { return .plainSQL }
        if url.pathExtension == "dump" { return .compressed }
        let dotless = url.deletingPathExtension().lastPathComponent
        return dotless.hasSuffix("dump") ? .compressed : .plainSQL
    }
}
