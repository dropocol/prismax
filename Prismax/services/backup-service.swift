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
        case toolMissing(provider: Provider, tool: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedProvider(let s):
                return "Unsupported database provider in URL scheme: \(s)"
            case .missingURL:
                return "No DATABASE_URL is set for this environment."
            case .launchFailed(let s):
                return "Could not launch backup tool: \(s)"
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
        // Embed the provider + format in the filename so backups can be labeled
        // accurately when listed later (the extension alone is ambiguous:
        // mysql and sqlite both use .sql).
        let fileURL = directory.appendingPathComponent("\(environmentName)-\(provider.rawValue)-\(stamp)\(BackupService.Provider.fileExtension(for: provider, format: format))")

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

    /// Lists existing backups for a (project, environment), read from that
    /// environment's resolved backup directory.
    static func backups(project: Project, environment: EnvProfile) -> [BackupResult] {
        let dir = BackupSettings.resolvedURL(project: project, environment: environment)
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

    // MARK: Shell

    /// Directories where DB CLI tools (`pg_dump`, `psql`, `mysqldump`, `sqlite3`)
    /// commonly live. A GUI app inherits a minimal PATH (`/usr/bin:/bin:…`) and a
    /// login non-interactive zsh only sources `/etc/paths.d` + `.zprofile` —
    /// neither of which includes Homebrew (`/opt/homebrew/bin`), Postgres.app, or
    /// `libpq` on a typical setup, since those are added in interactive `.zshrc`.
    /// We prepend any of these that exist so the tools resolve regardless.
    private static let dbToolPathDirs: [String] = [
        "/opt/homebrew/bin",                                   // Apple Silicon Homebrew
        "/opt/homebrew/opt/libpq/bin",                         // Homebrew libpq (pg tools)
        "/usr/local/bin",                                      // Intel Homebrew
        "/usr/local/opt/libpq/bin",
        "/Applications/Postgres.app/Contents/Versions/Latest/bin", // Postgres.app
        "/Library/PostgreSQL/17/bin",                          // EnterpriseDB installers
        "/Library/PostgreSQL/16/bin",
        "/Library/PostgreSQL/15/bin",
        "/Library/PostgreSQL/14/bin",
    ]

    /// Executes the shell command via the user's **default login shell** with DB
    /// tool directories prepended to PATH, so `pg_dump`/`psql`/`mysqldump`/
    /// `sqlite3` (installed via Homebrew, Postgres.app, libpq, …) are found even
    /// though a GUI app inherits only a minimal PATH. The resolved project
    /// environment is overlaid on top so the environment's `DATABASE_URL` /
    /// `MYSQL_PWD` reach the tool.
    ///
    /// We use the user's configured login shell (from `getpwuid`/`$SHELL`),
    /// not a hardcoded `/bin/zsh`, so PATH contributions from `.bash_profile`,
    /// `.config/fish`, etc. are honored for non-zsh users. The shell runs
    /// non-interactively (`-l -c` / `bash -lc`) so interactive banners/prompts
    /// never leak into captured output.
    ///
    /// Before spawning we pre-flight the command's tool against PATH; if it's
    /// missing we raise a clear, actionable `toolMissing` error (with install
    /// hints) instead of a cryptic "Exit 127: command not found".
    @discardableResult
    static func run(command: ShellCommand) async throws -> String {
        let env = Self.resolvedEnvironment(overlaying: command.extraEnvironment)

        // Pre-flight: confirm the tool resolves on PATH so we can surface a
        // helpful error rather than "exit 127". Checked against the same PATH
        // the command will actually use.
        if let tool = command.tool {
            try ensureToolAvailable(tool, in: env)
        }

        let (shell, args) = Self.loginShell(for: command.commandLine)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = args
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

    // MARK: Shell resolution

    /// The augmented environment: inherited env, overlaid with any extras
    /// (resolved `DATABASE_URL`, `MYSQL_PWD`), with well-known DB tool
    /// directories prepended to PATH.
    private static func resolvedEnvironment(overlaying extras: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extras { env[k] = v }
        env["PATH"] = augmentedPATH(base: env["PATH"] ?? "")
        return env
    }

    /// Returns the user's default login shell and the arg vector to run
    /// `commandLine` as a non-interactive login shell. Falls back to `/bin/sh`
    /// if the configured shell can't be determined (always present on macOS).
    ///
    /// Using the user's own shell (bash/fish/zsh) means their profile's PATH
    /// contributions (`.bash_profile`, `~/.config/fish/config.fish`, …) load,
    /// not just zsh's `.zprofile`.
    private static func loginShell(for commandLine: String) -> (shell: String, args: [String]) {
        let shell = defaultShell()
        // zsh/bash both honor `-l -c`; fish uses `-l -c`; sh/dash use `-c`.
        switch (shell as NSString).lastPathComponent {
        case "zsh", "bash":
            return (shell, ["-l", "-c", commandLine])
        case "fish":
            return (shell, ["-l", "-c", commandLine])
        default:
            // /bin/sh fallback (always available): not a login shell, but PATH
            // augmentation above already covers the common tool locations.
            return ("/bin/sh", ["-c", commandLine])
        }
    }

    /// The user's configured login shell, from the passwd database, falling back
    /// to `$SHELL` and finally `/bin/sh`.
    private static func defaultShell() -> String {
        if let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell,
           let shell = String(cString: s, encoding: .utf8), !shell.isEmpty {
            return shell
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/sh"
    }

    /// Raises `toolMissing` (with provider-specific install hints) if `tool`
    /// does not resolve on PATH in `env`. The provider is inferred from the tool
    /// name so the error message is accurate (pg_* → postgres, mysql* → mysql).
    private static func ensureToolAvailable(_ tool: String, in env: [String: String]) throws {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [tool]
        which.environment = env
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = pipe
        do { try which.run() } catch { return } // if `which` itself fails, let the real command fail naturally
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        which.waitUntilExit()
        guard which.terminationStatus == 0 else {
            throw BackupError.toolMissing(provider: Self.provider(forTool: tool), tool: tool)
        }
    }

    /// Infers the DB provider from a CLI tool name, for error messaging.
    private static func provider(forTool tool: String) -> Provider {
        let t = tool.lowercased()
        if t.hasPrefix("pg") || t == "psql" { return .postgres }
        if t.hasPrefix("mysql") { return .mysql }
        if t.hasPrefix("sqlite") { return .sqlite }
        return .postgres // best-effort default
    }

    /// Builds a PATH string with existing DB tool directories (those that exist
    /// on disk) prepended to `base`, de-duplicated.
    private static func augmentedPATH(base: String) -> String {
        let fm = FileManager.default
        var seen = Set<String>()
        let prepend = dbToolPathDirs.filter { fm.isExecutableFile(atPath: $0) && seen.insert($0).inserted }
        return (prepend + [base]).joined(separator: ":")
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - Supporting types

/// A shell command line plus optional extra environment. Executed via the
/// user's login shell with DB tool dirs prepended to PATH.
struct ShellCommand {
    /// The full command string executed as `login-shell -l -c <commandLine>`.
    let commandLine: String
    /// The CLI tool name (first token of `commandLine`), used for a pre-flight
    /// availability check so missing tools surface a clear error. Derived
    /// automatically when built via `init(commandLine:)`.
    var tool: String?
    /// Extra environment variables overlaid on the process's inherited env.
    /// Used to pass `MYSQL_PWD` (and the resolved `DATABASE_URL`) so
    /// credentials never appear on the command line.
    var extraEnvironment: [String: String] = [:]

    init(commandLine: String, extraEnvironment: [String: String] = [:]) {
        self.commandLine = commandLine
        self.tool = ShellCommand.firstToken(of: commandLine)
        self.extraEnvironment = extraEnvironment
    }

    /// Extracts the first whitespace-delimited token (the tool name).
    private static func firstToken(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let end = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return trimmed.isEmpty ? nil : trimmed
        }
        let tok = String(trimmed[..<end])
        return tok.isEmpty ? nil : tok
    }
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
