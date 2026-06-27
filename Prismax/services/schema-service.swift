import Foundation

/// High-level introspection service: parses the schema file and runs
/// `prisma migrate status` to report migration state.
///
/// The prisma command runs through `ShellRunner` (the same path the integrated
/// terminal and backup service use), so it inherits the user's full PATH
/// (Homebrew, nvm, fnm, …) rather than the minimal PATH a GUI app gets —
/// without that, `npx`/`node` resolve to "command not found".
///
/// Operates on a `Sendable` snapshot so it can cross async boundaries safely
/// under Swift 6 concurrency (SwiftData @Model classes are not Sendable).
enum SchemaService {

    struct Introspection {
        var schema: SchemaParser.Schema
        var migrateStatus: MigrateStatus
    }

    /// A `Sendable` snapshot of the data needed to run introspection.
    struct Snapshot: Sendable {
        var projectID: UUID
        var path: String
        var prismaDir: String
        var schemaPath: String
        var packageManager: PackageManager
        var envVars: [String: String]

        /// Absolute working directory commands should run from.
        var commandDirectory: String {
            if prismaDir.isEmpty { return path }
            return (path as NSString).appendingPathComponent(prismaDir)
        }
    }

    struct MigrateStatus {
        var succeeded: Bool
        var output: String
        var pendingCount: Int
        var appliedCount: Int
        var databaseURLMasked: String?
    }

    /// Builds a `Sendable` snapshot from the project + environment. Main-actor
    /// isolated because it reads Keychain values via `EnvironmentResolver`.
    @MainActor
    static func snapshot(project: Project, environment env: EnvProfile) -> Snapshot {
        Snapshot(
            projectID: project.id,
            path: project.path,
            prismaDir: project.prismaDir ?? "",
            schemaPath: project.schemaPath,
            packageManager: project.packageManager,
            envVars: EnvironmentResolver.resolve(project: project, environment: env)
        )
    }

    /// Runs introspection from a snapshot (safe to call off the main actor).
    static func introspect(snapshot: Snapshot) async -> Introspection {
        let schema = readSchema(path: snapshot.path, schemaPath: snapshot.schemaPath)
        let status = await runMigrateStatus(snapshot: snapshot, schema: schema)
        return Introspection(schema: schema, migrateStatus: status)
    }

    /// Reads and parses the schema file (or returns an empty schema if missing).
    static func readSchema(path: String, schemaPath: String) -> SchemaParser.Schema {
        let full = (path as NSString).appendingPathComponent(schemaPath)
        return SchemaParser.parseFile(at: full)
    }

    /// Runs `prisma migrate status` and parses the output.
    static func runMigrateStatus(
        snapshot: Snapshot,
        schema: SchemaParser.Schema
    ) async -> MigrateStatus {
        let builder = PrismaCommandBuilder(
            packageManager: snapshot.packageManager,
            prismaDir: snapshot.prismaDir,
            schemaPath: snapshot.schemaPath
        )
        let commandLine = builder.commandString(for: "migrate status")

        // Run through `ShellRunner` (the same path the integrated terminal and
        // backup service use): it runs the user's login shell with well-known
        // tool directories — including Homebrew's `/opt/homebrew/bin`, where
        // `node`/`npx` live on a `brew install node` setup — prepended to PATH.
        // A GUI app only inherits a minimal PATH, so without this `npx` resolves
        // to "command not found" even though it works fine in a real terminal.
        // Env vars ride along via `extraEnvironment` so secrets (DATABASE_URL,
        // MYSQL_PWD, …) reach the process without appearing on the command line.
        let command = ShellCommand(
            commandLine: commandLine,
            extraEnvironment: snapshot.envVars
        )

        // ShellRunner throws on non-zero exit (and surfaces a clear "tool
        // missing" error via its pre-flight `which`). For the status card we
        // want to show whatever output we got either way, so capture success
        // vs. failure text here rather than letting an exception escape. The
        // timeout keeps an unreachable database from hanging the UI forever —
        // `prisma migrate status` will otherwise block on the TCP connection.
        let output: String
        let succeeded: Bool
        do {
            output = try await ShellRunner.run(
                command: command,
                directory: snapshot.commandDirectory,
                timeout: 20
            )
            succeeded = true
        } catch {
            output = "\(error.localizedDescription)"
            succeeded = false
        }

        // The command runs through the user's login shell, which can occasionally
        // emit banner/echo noise from .zprofile or a version manager (e.g.
        // "🚀 ZK-Scripts loaded!"). Strip lines that are obviously shell startup
        // chatter so only real prisma output reaches the UI.
        let cleaned = Self.stripShellNoise(from: output)

        // Total migrations is read from disk (each subdir of prisma/migrations is
        // one migration) because Prisma's text output doesn't reliably state it,
        // and a naive string match can never report the count you actually have.
        // Pending is parsed from the command's "not yet applied" listing. Applied
        // is derived: total − pending.
        let total = Self.countMigrationsOnDisk(
            rootPath: snapshot.path,
            schemaPath: snapshot.schemaPath
        )
        let pending = Self.parsePending(from: cleaned)
        let applied = max(0, total - pending)

        return MigrateStatus(
            succeeded: succeeded,
            output: cleaned,
            pendingCount: succeeded ? pending : 0,
            appliedCount: succeeded ? applied : 0,
            databaseURLMasked: maskURL(schema.datasourceURL)
        )
    }

    // MARK: Helpers

    /// Removes shell-startup noise (banners, echo'd config paths) from captured
    /// command output so the UI shows only real tool output. Drops any leading
    /// lines that contain emoji or common banner markers ("loaded!", "Config:",
    /// "Tools:"), then trims leading blanks.
    private static func stripShellNoise(from output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var kept = [String]()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Emoji / symbol-prefixed banner lines.
            if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .otherSymbol || Self.isEmoji($0) }) {
                continue
            }
            // Common .zshrc/.zprofile banner fragments.
            let lower = trimmed.lowercased()
            if lower.contains("loaded!") || lower.hasPrefix("config:") || lower.hasPrefix("tools:") {
                continue
            }
            kept.append(String(line))
        }
        return kept.joined(separator: "\n")
    }

    /// True if the scalar is in a common emoji range (covers pictographs,
    /// emoji presentation base chars, and keycaps — enough to flag banner lines).
    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // Misc Symbols & Pictographs, Emoticons, Transport/Map, Supplemental
        // Symbols & Pictographs, and the dingbats/arrows often used in banners.
        return (0x1F300...0x1FAFF).contains(v)
            || (0x2600...0x27BF).contains(v)
            || (0x2190...0x21FF).contains(v)
            || (0x2B00...0x2BFF).contains(v)
    }

    /// Counts migration folders on disk. Each immediate subdirectory of the
    /// `migrations/` folder (sibling of `schema.prisma`) is one migration, named
    /// `<timestamp>_<name>`. This is the authoritative total — it reflects what's
    /// checked into the repo regardless of what the command prints.
    ///
    /// Resolves the migrations dir from the schema location: for
    /// `prisma/schema.prisma` it's `prisma/migrations`; for `db/schema.prisma`
    /// it's `db/migrations`. Returns 0 if the folder doesn't exist.
    private static func countMigrationsOnDisk(rootPath: String, schemaPath: String) -> Int {
        // The migrations dir is the schema's own directory + "/migrations".
        let schemaDir = (schemaPath as NSString).deletingLastPathComponent
        let migrationsRel = schemaDir.isEmpty
            ? "migrations"
            : schemaDir + "/migrations"
        let migrationsAbs = (rootPath as NSString).appendingPathComponent(migrationsRel)

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: migrationsAbs) else {
            return 0
        }
        let fm = FileManager.default
        return entries.reduce(0) { count, name in
            let full = (migrationsAbs as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            // Count directories only, skip dotfiles (e.g. the migration lockfile
            // `migration_lock.toml` is a file, so it's naturally excluded).
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else {
                return count
            }
            return name.hasPrefix(".") ? count : count + 1
        }
    }

    /// Counts pending migrations from `prisma migrate status` output. Prisma
    /// lists un-applied migrations each on its own line after a header like
    /// "Following migration(s) have not yet been applied:". the pending count is
    /// the number of timestamped migration entries under that header. If the
    /// output says the schema is up to date, there are no pending.
    private static func parsePending(from output: String) -> Int {
        let lower = output.lowercased()
        if lower.contains("database schema is up to date") { return 0 }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        var pending = 0
        var inPendingSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lowerLine = trimmed.lowercased()
            if lowerLine.contains("not yet applied") {
                inPendingSection = true
                continue
            }
            // A pending migration line looks like an indented timestamped name,
            // e.g. "20240424065014_init" or "└─ 20240424_init └─ migration.sql".
            // Prisma also renders a tree, so match lines that lead with a tree
            // char or whitespace and contain a timestamp-like token (8+ digits).
            if inPendingSection {
                if lowerLine.contains("following migration") { continue }
                if Self.looksLikeMigrationLine(trimmed) {
                    pending += 1
                } else if !trimmed.isEmpty && !lowerLine.contains("migrations found") {
                    // A non-empty, non-migration line ends the pending block.
                    inPendingSection = false
                }
            }
        }
        return pending
    }

    /// True if a line looks like a listed migration entry: contains a migration
    /// timestamp (8+ consecutive digits, matching Prisma's `<timestamp>_<name>`
    /// convention) and isn't itself a header/summary line.
    private static func looksLikeMigrationLine(_ line: String) -> Bool {
        // Count the longest run of consecutive digits; a migration timestamp is
        // 14 digits (YYYYMMDDHHMMSS), so 8+ is a safe match threshold.
        var run = 0
        var maxRun = 0
        for ch in line {
            if ch.isNumber {
                run += 1
                if run > maxRun { maxRun = run }
            } else {
                run = 0
            }
        }
        return maxRun >= 8
    }

    private static func maskURL(_ url: String?) -> String? {
        guard let url, let parsed = URL(string: url) else { return url }
        var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
        if components?.user != nil { components?.password = "••••" }
        return components?.url?.absoluteString
    }
}
