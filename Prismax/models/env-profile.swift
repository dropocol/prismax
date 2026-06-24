import Foundation
import SwiftData

/// A deployment target for a project (e.g. "development", "staging", "production").
///
/// Named `EnvProfile` (not `Environment`) to avoid shadowing SwiftUI's
/// `Environment` used by `@Environment`.
///
/// Variable keys live here; variable values are stored in the macOS Keychain and
/// loaded into the spawned process's environment at run time.
@Model
final class EnvProfile {
    @Attribute(.unique) var id: UUID
    var project: Project?

    var name: String
    /// Hex color used for the env dot/labels in the UI, e.g. "#34C759".
    var colorHex: String
    /// Path to the migrations directory relative to the project root (optional).
    var migrationsPath: String
    /// Optional path to a .env file (relative to project root, e.g. ".env.prod")
    /// whose contents are loaded alongside the Keychain variables. Lets you keep
    /// using your existing per-env .env files without re-entering secrets.
    /// Optional so existing stores migrate cleanly.
    var envFilePath: String?
    /// Display order within the project.
    var orderIndex: Int

    @Relationship(deleteRule: .cascade, inverse: \EnvVariable.environment)
    var variables: [EnvVariable] = []

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#8E8E93",
        migrationsPath: String = "prisma/migrations",
        envFilePath: String? = nil,
        orderIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.migrationsPath = migrationsPath
        self.envFilePath = envFilePath
        self.orderIndex = orderIndex
    }
}

/// A single environment variable definition. The value itself is NOT stored here —
/// it lives in the Keychain, keyed by `keychainAccount`.
@Model
final class EnvVariable {
    @Attribute(.unique) var id: UUID
    var environment: EnvProfile?

    var key: String
    /// Account name used to look up the value in the macOS Keychain.
    var keychainAccount: String

    init(id: UUID = UUID(), key: String, keychainAccount: String) {
        self.id = id
        self.key = key
        self.keychainAccount = keychainAccount
    }
}
