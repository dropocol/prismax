import Foundation
import SwiftData

/// A Prisma project on disk. The working directory commands are run from.
@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Absolute filesystem path to the project root (working directory for all commands).
    var path: String
    /// Detected package manager used to resolve the `prisma` executable.
    var packageManagerRaw: String
    /// Directory commands run from, relative to `path`. Empty means run from
    /// the project root. Derived from the schema location so Prisma finds
    /// `schema.prisma` via its default lookup — e.g. for a monorepo with the
    /// schema at `packages/db/prisma/schema.prisma`, this is `packages/db`.
    /// Optional so existing stores migrate cleanly (nil ≡ run from root).
    var prismaDir: String?
    /// Path to schema.prisma relative to `path` (e.g. "prisma/schema.prisma"). May be empty until detected.
    var schemaPath: String
    var createdAt: Date
    var orderIndex: Int

    @Relationship(deleteRule: .cascade, inverse: \EnvProfile.project)
    var environments: [EnvProfile] = []

    @Relationship(deleteRule: .cascade, inverse: \Command.project)
    var commands: [Command] = []

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        packageManager: PackageManager = .npm,
        prismaDir: String? = nil,
        schemaPath: String = "prisma/schema.prisma",
        createdAt: Date = .now,
        orderIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.packageManagerRaw = packageManager.rawValue
        self.prismaDir = prismaDir
        self.schemaPath = schemaPath
        self.createdAt = createdAt
        self.orderIndex = orderIndex
    }

    var packageManager: PackageManager {
        get { PackageManager(rawValue: packageManagerRaw) ?? .npm }
        set { packageManagerRaw = newValue.rawValue }
    }

    /// Absolute working directory commands should run from: `path` joined with
    /// `prismaDir`. When `prismaDir` is nil/empty this is just the project root.
    var commandDirectory: String {
        let dir = prismaDir ?? ""
        if dir.isEmpty { return path }
        return (path as NSString).appendingPathComponent(dir)
    }
}

/// Node package managers we know how to invoke prisma through.
enum PackageManager: String, Codable, CaseIterable, Identifiable {
    case npm, pnpm, yarn, bun
    var id: String { rawValue }

    /// Human-friendly label for pickers.
    var label: String {
        switch self {
        case .npm: "npm"
        case .pnpm: "pnpm"
        case .yarn: "yarn"
        case .bun: "bun"
        }
    }

    /// Lockfile presence that implies this package manager.
    var lockfileName: String {
        switch self {
        case .npm: "package-lock.json"
        case .pnpm: "pnpm-lock.yaml"
        case .yarn: "yarn.lock"
        case .bun: "bun.lockb"
        }
    }

    /// The shell tokens that run `prisma` through this package manager.
    /// `PrismaCommandBuilder` consumes these (executable + args).
    var prismaInvocation: (executable: String, args: [String]) {
        switch self {
        case .npm: ("npx", ["prisma"])
        case .pnpm: ("pnpm", ["exec", "prisma"])
        case .yarn: ("yarn", ["prisma"])
        case .bun: ("bunx", ["prisma"])
        }
    }
}
