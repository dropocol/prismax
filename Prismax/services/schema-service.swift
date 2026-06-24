import Foundation

/// High-level introspection service: parses the schema file and runs
/// `prisma migrate status` to report migration state.
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
        let commandTokens = builder.commandString(for: "migrate status")
            .split(separator: " ").map(String.init).map(shellQuote)
            .joined(separator: " ")

        // Run through a login shell so the user's full PATH (Homebrew, nvm,
        // fnm, volta, etc.) is loaded; GUI apps inherit a minimal PATH.
        // Export each Keychain env var so it takes precedence.
        let exports = snapshot.envVars
            .map { "export \(shellQuote($0.key))=\(shellQuote($0.value));" }
            .joined(separator: " ")
        let shellCommand = exports.isEmpty ? commandTokens : "\(exports) \(commandTokens)"

        let result = await ProcessRunner.run(
            shellCommand: shellCommand,
            directory: snapshot.commandDirectory
        )

        let pending = countMatches(of: "not yet applied", in: result.combinedOutput)
        let applied = countMatches(of: "Following migration", in: result.combinedOutput)

        return MigrateStatus(
            succeeded: result.isSuccess,
            output: result.combinedOutput,
            pendingCount: pending,
            appliedCount: applied,
            databaseURLMasked: maskURL(schema.datasourceURL)
        )
    }

    // MARK: Helpers

    private static func countMatches(of needle: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, options: .caseInsensitive, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    private static func maskURL(_ url: String?) -> String? {
        guard let url, let parsed = URL(string: url) else { return url }
        var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
        if components?.user != nil { components?.password = "••••" }
        return components?.url?.absoluteString
    }
}
