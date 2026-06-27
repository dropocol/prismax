import Foundation

/// Builds the prisma invocation for a project as a single source of truth.
///
/// Resolves the package-manager executable (`npx prisma`, `pnpm dlx prisma`,
/// …), appends the user's prisma args, and conditionally adds `--schema`
/// (relativized to the command dir for monorepo support). Both the integrated
/// terminal and `SchemaService` route through here so command construction can
/// never drift between the two run paths.
///
/// `Sendable` so it can cross actor boundaries (e.g. into SchemaService's
/// off-main-actor introspection).
struct PrismaCommandBuilder: Sendable {
    let packageManager: PackageManager
    /// Directory commands run from, relative to the project root. Empty = root.
    let prismaDir: String
    /// Path to `schema.prisma` relative to the project root.
    let schemaPath: String

    init(project: Project) {
        self.init(
            packageManager: project.packageManager,
            prismaDir: project.prismaDir ?? "",
            schemaPath: project.schemaPath
        )
    }

    init(packageManager: PackageManager, prismaDir: String, schemaPath: String) {
        self.packageManager = packageManager
        self.prismaDir = prismaDir
        self.schemaPath = schemaPath
    }

    /// The shell tokens that launch prisma for this project's package manager,
    /// e.g. `["npx", "prisma"]` or `["pnpm", "dlx", "prisma"]`.
    private var prismaTokens: [String] {
        let (executable, baseArgs) = packageManager.prismaInvocation
        return [executable] + baseArgs
    }

    /// Builds the full command for `prismaArgs` (everything after `prisma`),
    /// e.g. `prismaArgs = "migrate deploy"` → `"npx prisma migrate deploy"`.
    ///
    /// Suitable for typing into an interactive shell as-is (no quoting).
    func commandString(for prismaArgs: String) -> String {
        var tokens = prismaTokens + Self.tokenize(prismaArgs)
        if shouldPassSchema {
            tokens += ["--schema", schemaPathRelative(toCommandDir: prismaDir, schemaPath: schemaPath)]
        }
        return tokens.joined(separator: " ")
    }

    /// Whether to append `--schema`. We always pass it in a subdirectory run
    /// (monorepo), where Prisma's default lookup may not find the schema; the
    /// `includeSchemaArg` setting forces it on for root-level runs too.
    private var shouldPassSchema: Bool {
        guard !schemaPath.isEmpty else { return false }
        if Self.includeSchemaArg { return true }
        return !prismaDir.isEmpty
    }

    /// Splits a freeform args string into tokens, dropping empties.
    static func tokenize(_ args: String) -> [String] {
        args.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// Reads the user-facing "always pass --schema" setting.
    static var includeSchemaArg: Bool {
        UserDefaults.standard.bool(forKey: "includeSchemaArg")
    }
}

/// Converts a schema path (relative to the project root) into one relative to
/// the command dir, so it resolves correctly when the process runs from
/// `commandDirectory` instead of the project root. If `prismaDir` is empty
/// (running from root) the path is returned unchanged.
///
/// e.g. prismaDir="packages/db", schemaPath="packages/db/prisma/schema.prisma"
///      → "prisma/schema.prisma"
func schemaPathRelative(toCommandDir prismaDir: String, schemaPath: String) -> String {
    guard !prismaDir.isEmpty else { return schemaPath }
    let prefix = prismaDir.hasSuffix("/") ? prismaDir : prismaDir + "/"
    if schemaPath.hasPrefix(prefix) {
        return String(schemaPath.dropFirst(prefix.count))
    }
    return schemaPath
}
