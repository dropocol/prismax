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

    /// Builds a `Sendable` snapshot from the project + environment (main actor).
    static func snapshot(project: Project, environment env: EnvProfile) -> Snapshot {
        Snapshot(
            projectID: project.id,
            path: project.path,
            prismaDir: project.prismaDir ?? "",
            schemaPath: project.schemaPath,
            packageManager: project.packageManager,
            envVars: PrismaRunnerStatic.resolveEnvironment(project: project, environment: env)
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
        let (executable, args) = snapshot.packageManager.prismaInvocation
        var tokens = [executable] + args + ["migrate", "status"]
        // If the schema isn't at a path Prisma finds by default from the command
        // dir, point at it explicitly (relative to the command dir).
        if !snapshot.prismaDir.isEmpty, !snapshot.schemaPath.isEmpty {
            let prefix = snapshot.prismaDir.hasSuffix("/") ? snapshot.prismaDir : snapshot.prismaDir + "/"
            if snapshot.schemaPath.hasPrefix(prefix) {
                tokens += ["--schema", String(snapshot.schemaPath.dropFirst(prefix.count))]
            } else {
                tokens += ["--schema", snapshot.schemaPath]
            }
        }
        let commandTokens = tokens.map { shellQuote($0) }.joined(separator: " ")

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

/// Static access to PrismaRunner's env-resolution helpers. This tiny shim lets
/// SchemaService resolve env vars without holding a PrismaRunner instance.
enum PrismaRunnerStatic {
    /// Builds the environment dictionary for a spawned process: inherits the
    /// base environment, overlays a referenced .env file (if any), then overlays
    /// Keychain values (which take precedence).
    static func resolveEnvironment(project: Project, environment env: EnvProfile) -> [String: String] {
        var combined = ProcessInfo.processInfo.environment

        // 1. Optional .env file referenced by the environment.
        if let envFilePath = env.envFilePath, !envFilePath.isEmpty {
            let full = (project.path as NSString).appendingPathComponent(envFilePath)
            if let data = FileManager.default.contents(atPath: full),
               let text = String(data: data, encoding: .utf8) {
                for pair in EnvFileImporter.parse(text) {
                    combined[pair.key] = pair.value
                }
            }
        }

        // 2. Keychain variables (take precedence over the .env file).
        for variable in env.variables {
            if let value = try? KeychainService.get(account: variable.keychainAccount) {
                combined[variable.key] = value
            }
        }
        return combined
    }
}
