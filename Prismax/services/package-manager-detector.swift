import Foundation

/// Detects a project's package manager and the location of `schema.prisma`
/// by inspecting the filesystem.
enum PackageManagerDetector {

    struct Detection {
        var packageManager: PackageManager
        /// Directory commands should run from, relative to the project root.
        /// Empty means run from the root. Derived from where the schema lives.
        var prismaDir: String
        /// Path to `schema.prisma`, relative to the project root.
        var schemaPath: String
    }

    /// Inspects `projectPath` for lockfiles and a `schema.prisma` file.
    static func detect(at projectPath: String) -> Detection {
        let fm = FileManager.default
        let pm: PackageManager = {
            // Bun and pnpm take precedence over yarn/npm to avoid ambiguity,
            // since a repo may contain multiple lockfiles.
            if exists(fm, at: projectPath, relative: PackageManager.bun.lockfileName) { return .bun }
            if exists(fm, at: projectPath, relative: PackageManager.pnpm.lockfileName) { return .pnpm }
            if exists(fm, at: projectPath, relative: PackageManager.yarn.lockfileName) { return .yarn }
            if exists(fm, at: projectPath, relative: PackageManager.npm.lockfileName) { return .npm }
            return .npm
        }()

        let schemaPath = locateSchema(fm: fm, at: projectPath)
        let prismaDir = prismaDir(forSchemaPath: schemaPath)
        return Detection(packageManager: pm, prismaDir: prismaDir, schemaPath: schemaPath)
    }

    private static func exists(_ fm: FileManager, at root: String, relative: String) -> Bool {
        fm.fileExists(atPath: (root as NSString).appendingPathComponent(relative))
    }

    /// Derives the command directory (relative to root) from the schema path.
    /// Prisma's default lookup searches for `schema.prisma` in the cwd, then in
    /// a `prisma/` subfolder of the cwd — so we want to run from the folder that
    /// *contains* the `prisma/` folder (or contains the schema file directly).
    ///
    /// Examples (schema path → prismaDir):
    ///   prisma/schema.prisma          → ""        (run from root)
    ///   db/schema.prisma              → "db"
    ///   schema.prisma                 → ""
    ///   packages/db/prisma/schema.prisma → "packages/db"
    ///   packages/db/schema.prisma     → "packages/db"
    static func prismaDir(forSchemaPath schemaPath: String) -> String {
        let components = (schemaPath as NSString).pathComponents
        // Drop the filename; what's left is the directory holding the schema.
        let schemaDir = components.dropLast()
        // If the schema sits inside a `prisma/` folder, step above it — that's
        // the package dir Prisma resolves from by default. Otherwise the schema
        // dir itself is the command dir.
        let dirComponents: [String]
        if let last = schemaDir.last, last == "prisma" {
            dirComponents = Array(schemaDir.dropLast())
        } else {
            dirComponents = Array(schemaDir)
        }
        // A root-level schema (or `prisma/schema.prisma`) → run from root.
        if dirComponents.isEmpty { return "" }
        return dirComponents.joined(separator: "/")
    }

    // MARK: - Schema discovery

    /// Directories we never descend into during the recursive search.
    private static let skippedDirs: Set<String> = [
        "node_modules", ".git", ".next", "dist", "build",
        ".turbo", ".svelte-kit", ".cache", "out", "coverage", ".vercel"
    ]

    /// Searches for `schema.prisma` using a priority list (first match wins):
    ///   1. `package.json` → `prisma.schema` field (Prisma's canonical config)
    ///   2. Common locations (prisma/schema.prisma, db/schema.prisma, …)
    ///   3. Recursive search (skipping node_modules/.git/etc.)
    ///   4. Fallback: prisma/schema.prisma
    private static func locateSchema(fm: FileManager, at root: String) -> String {
        // 1. package.json prisma.schema — the canonical source of truth.
        if let pkgSchema = schemaFromPackageJSON(fm: fm, at: root) {
            // Normalize to a path relative to root if possible.
            let rel = relativize(pkgSchema, to: root)
            if !rel.isEmpty {
                return rel
            }
        }

        // 2. Common locations.
        let candidates = [
            "prisma/schema.prisma",
            "prisma/schema",
            "db/schema.prisma",
            "schema.prisma"
        ]
        for candidate in candidates {
            if exists(fm, at: root, relative: candidate) { return candidate }
        }

        // 3. Recursive search: shallowest schema.prisma, preferring paths that
        //    contain a "prisma" segment (the conventional layout).
        if let found = recursiveFindSchema(fm: fm, at: root) {
            return found
        }

        // 4. Fallback.
        return "prisma/schema.prisma"
    }

    /// Reads `prisma.schema` from `package.json` (top-level or a nested
    /// `"prisma": { "schema": "..." }` form). Returns the raw value.
    private static func schemaFromPackageJSON(fm: FileManager, at root: String) -> String? {
        let pkgURL = URL(fileURLWithPath: (root as NSString).appendingPathComponent("package.json"))
        guard let data = fm.contents(atPath: pkgURL.path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let prisma = obj["prisma"] as? [String: Any], let s = prisma["schema"] as? String {
            return s
        }
        if let s = obj["prisma"] as? String {
            return s
        }
        return nil
    }

    /// Converts an absolute path to one relative to `root`; leaves relative
    /// paths as-is.
    private static func relativize(_ p: String, to root: String) -> String {
        if p.hasPrefix("/") {
            let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
            if p.hasPrefix(rootWithSlash) {
                return String(p.dropFirst(rootWithSlash.count))
            }
            return p
        }
        return p
    }

    /// Recursively searches for `schema.prisma`, returning the shallowest match
    /// (fewest path components). Ties are broken in favor of paths containing a
    /// `prisma` segment. Blocked directories (node_modules, .git, …) are pruned
    /// outright via `skipDescendants` so a large `node_modules` can't exhaust
    /// the search budget before the schema is reached.
    private static func recursiveFindSchema(fm: FileManager, at root: String) -> String? {
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (path: String, depth: Int, isPrismaDir: Bool)?
        var examined = 0
        let limit = 10_000

        for case let url as URL in enumerator {
            examined += 1
            if examined > limit { break }

            // Prune blocked subtrees (node_modules, .git, …) so they don't
            // consume the search budget. `skipDescendants()` (no argument)
            // skips descent into the most recently returned item.
            let name = url.lastPathComponent
            if skippedDirs.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            guard name == "schema.prisma" else { continue }

            // Relative path from root.
            let abs = url.path
            guard abs.hasPrefix(root) else { continue }
            let rel = String(abs.dropFirst(root.count).drop(while: { $0 == "/" }))
            let depth = rel.split(separator: "/").count
            let isPrismaDir = rel.lowercased().contains("/prisma/")
            let cand = (path: rel, depth: depth, isPrismaDir: isPrismaDir)

            if best == nil { best = cand; continue }
            guard let b = best else { continue }
            // Prefer shallower; among equal depth prefer prisma dir.
            if depth < b.depth || (depth == b.depth && isPrismaDir && !b.isPrismaDir) {
                best = cand
            }
        }

        return best?.path
    }
}
