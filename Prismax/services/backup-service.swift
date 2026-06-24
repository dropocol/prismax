import Foundation
import AppKit

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
    static func backup(
        databaseURL: String,
        project projectID: UUID,
        environment envID: UUID,
        environmentName: String
    ) async throws -> BackupResult {
        guard let url = URL(string: databaseURL), let scheme = url.scheme,
              let provider = Provider(urlScheme: scheme) else {
            throw BackupError.unsupportedProvider(URL(string: databaseURL)?.scheme ?? "(none)")
        }

        let dir = backupDirectory(projectID: projectID, envID: envID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = Self.timestamp()
        // Embed the provider in the filename so backups can be labeled
        // accurately when listed later (the extension alone is ambiguous:
        // mysql and sqlite both use .sql).
        let fileURL = dir.appendingPathComponent("\(environmentName)-\(provider.rawValue)-\(stamp)\(provider.fileExtension)")

        let command = try backupCommand(provider: provider, url: url, outputFile: fileURL)
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

    static func restore(databaseURL: String, from fileURL: URL) async throws -> String {
        guard let url = URL(string: databaseURL), let scheme = url.scheme,
              let provider = Provider(urlScheme: scheme) else {
            throw BackupError.unsupportedProvider(URL(string: databaseURL)?.scheme ?? "(none)")
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BackupError.restoreFailed("Backup file not found.")
        }
        let command = try restoreCommand(provider: provider, url: url, inputFile: fileURL)
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
            .appendingPathComponent("Prismax", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent(envID.uuidString, isDirectory: true)
        return base
    }

    // MARK: Command building

    private static func backupCommand(provider: Provider, url: URL, outputFile: URL) throws -> ShellCommand {
        switch provider {
        case .postgres:
            // Prefer connection string form (works with pg_dump 16+).
            return ShellCommand(
                executable: "/bin/sh",
                arguments: ["-c", "pg_dump \"\(url.absoluteString)\" -F c -f \"\(outputFile.path)\""]
            )
        case .mysql:
            guard let host = url.host, let port = url.port else { throw BackupError.missingURL }
            // Credentials are passed via MYSQL_PWD in the process environment
            // (set in `extraEnvironment` by the caller), never on the command
            // line — avoiding both shell injection and exposure in `ps`.
            var cmd = ShellCommand(
                executable: "/bin/sh",
                arguments: ["-c", "mysqldump -h \(shellQuote(host)) -P \(port) -u \(shellQuote(url.user ?? "root")) \(shellQuote(url.lastPathComponent)) > \"\(outputFile.path)\""]
            )
            if let pwd = url.password { cmd.extraEnvironment["MYSQL_PWD"] = pwd }
            return cmd
        case .sqlite:
            // url.path is the database file path for sqlite.
            return ShellCommand(
                executable: "/bin/sh",
                arguments: ["-c", "sqlite3 \"\(url.path)\" .dump > \"\(outputFile.path)\""]
            )
        }
    }

    private static func restoreCommand(provider: Provider, url: URL, inputFile: URL) throws -> ShellCommand {
        switch provider {
        case .postgres:
            return ShellCommand(
                executable: "/bin/sh",
                arguments: ["-c", "pg_restore --clean --if-exists -d \"\(url.absoluteString)\" \"\(inputFile.path)\""]
            )
        case .mysql:
            guard let host = url.host, let port = url.port else { throw BackupError.missingURL }
            var cmd = ShellCommand(
                executable: "/bin/sh",
                arguments: ["-c", "mysql -h \(shellQuote(host)) -P \(port) -u \(shellQuote(url.user ?? "root")) \(shellQuote(url.lastPathComponent)) < \"\(inputFile.path)\""]
            )
            if let pwd = url.password { cmd.extraEnvironment["MYSQL_PWD"] = pwd }
            return cmd
        case .sqlite:
            return ShellCommand(
                executable: "/bin/sh",
                arguments: ["-c", "sqlite3 \"\(url.path)\" < \"\(inputFile.path)\""]
            )
        }
    }

    // MARK: Shell

    @discardableResult
    static func run(command: ShellCommand) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        // Overlay any extra env (e.g. MYSQL_PWD) onto the inherited environment.
        if !command.extraEnvironment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in command.extraEnvironment { env[k] = v }
            process.environment = env
        }

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

struct ShellCommand {
    let executable: String
    let arguments: [String]
    /// Extra environment variables overlaid on the process's inherited env.
    /// Used to pass `MYSQL_PWD` so credentials never appear on the command line.
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
    var fileExtension: String {
        switch self {
        case .postgres: "dump"
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
