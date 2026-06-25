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
        case launchFailed(String)
        case restoreFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedProvider(let s): "Unsupported database provider in URL scheme: \(s)"
            case .missingURL: "No DATABASE_URL is set for this environment."
            case .launchFailed(let s): "Could not launch backup tool: \(s)"
            case .restoreFailed(let s): "Restore failed: \(s)"
            }
        }
    }

    // MARK: Backup

    /// Creates a timestamped backup file under the app's Application Support dir.
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
        project projectID: UUID,
        environment envID: UUID,
        environmentName: String,
        format: BackupFormat = .compressed,
        schemaOnly: Bool = false
    ) async throws -> BackupResult {
        guard let url = URL(string: databaseURL), let scheme = url.scheme,
              let provider = Provider(urlScheme: scheme) else {
            throw BackupError.unsupportedProvider(URL(string: databaseURL)?.scheme ?? "(none)")
        }

        let dir = backupDirectory(projectID: projectID, envID: envID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = Self.timestamp()
        // Embed the provider + format in the filename so backups can be labeled
        // accurately when listed later (the extension alone is ambiguous:
        // mysql and sqlite both use .sql).
        let fileURL = dir.appendingPathComponent("\(environmentName)-\(provider.rawValue)-\(stamp)\(BackupService.Provider.fileExtension(for: provider, format: format))")

        let command = try backupCommand(provider: provider, url: url, outputFile: fileURL, format: format, schemaOnly: schemaOnly)
        let output = try await run(command: command)

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
        return try await run(command: command)
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
        return try await run(command: command)
    }

    // MARK: Listing

    static func backups(projectID: UUID, envID: UUID) -> [BackupResult] {
        let dir = backupDirectory(projectID: projectID, envID: envID)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "sql" || $0.pathExtension == "dump" }
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

    static func delete(fileURL: URL) throws {
        try FileManager.default.removeItem(at: fileURL)
    }

    static func reveal(fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: Paths

    static func backupDirectory(projectID: UUID, envID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PrismaX", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent(envID.uuidString, isDirectory: true)
        return base
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

    // MARK: Shell

    /// Executes the shell command via a **login** zsh so that tools installed
    /// by the user (`pg_dump`, `psql`, `mysqldump` via Postgres.app, Homebrew,
    /// DBngin, …) are found on PATH. A GUI app inherits only a minimal PATH
    /// (`/usr/bin:/bin:…`), so a raw `/bin/sh` fails with "command not found".
    ///
    /// Login but non-interactive (`-l -c`): loads `.zprofile` PATH contributions
    /// without sourcing interactive `.zshrc` banners. The resolved environment
    /// from `EnvironmentResolver` is overlaid on top of the login shell's env so
    /// the project's `DATABASE_URL` / `MYSQL_PWD` reach the tool.
    @discardableResult
    static func run(command: ShellCommand) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command.commandLine]

        // Start from the login shell's environment, overlay the resolved
        // project environment (DB URL, MYSQL_PWD, …).
        var env = ProcessInfo.processInfo.environment
        for (k, v) in command.extraEnvironment { env[k] = v }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch { throw BackupError.launchFailed(error.localizedDescription) }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw BackupError.launchFailed("Exit \(process.terminationStatus): \(output)")
        }
        return output
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - Supporting types

/// A shell command line plus optional extra environment. Executed via a login
/// zsh so user-installed DB tools resolve on PATH.
struct ShellCommand {
    /// The full command string executed by `/bin/zsh -l -c`.
    let commandLine: String
    /// Extra environment variables overlaid on the process's inherited env.
    /// Used to pass `MYSQL_PWD` (and the resolved `DATABASE_URL`) so
    /// credentials never appear on the command line.
    var extraEnvironment: [String: String] = [:]
}

struct BackupResult: Identifiable {
    var id: URL { fileURL }
    let fileURL: URL
    let provider: BackupService.Provider
    var sizeBytes: Int
    var output: String
    var createdAt: Date
}

extension BackupService.Provider {
    /// File extension for a fresh backup of this provider in the given format.
    /// Postgres distinguishes compressed (`.dump`) from plain (`.sql`); the
    /// others always emit SQL text.
    static func fileExtension(for provider: BackupService.Provider, format: BackupFormat) -> String {
        switch provider {
        case .postgres: format == .compressed ? "dump" : "sql"
        case .mysql, .sqlite: "sql"
        }
    }

    /// Derives the provider from a backup filename, falling back to the
    /// extension. New backups embed the provider in the name
    /// (`{env}-{provider}-{stamp}`); older ones without it are inferred:
    /// `.dump` → postgres, `.sql` → mysql (the more common of the two; sqlite
    /// dumps are rare and we can't tell from the extension alone).
    static func provider(for url: URL) -> BackupService.Provider {
        let name = url.deletingPathExtension().lastPathComponent
        for part in name.split(separator: "-") {
            if let provider = BackupService.Provider(rawValue: String(part)) {
                return provider
            }
        }
        return url.pathExtension == "dump" ? .postgres : .mysql
    }
}

extension BackupFormat {
    /// Infers the on-disk format of an existing backup file for a given
    /// provider, so restore can pick the right tool (`pg_restore` vs `psql`).
    /// Postgres `.dump` → compressed; everything else (`.sql`) → plainSQL.
    static func format(for url: URL, provider: BackupService.Provider) -> BackupFormat {
        guard provider == .postgres else { return .plainSQL }
        return url.pathExtension == "dump" ? .compressed : .plainSQL
    }
}
