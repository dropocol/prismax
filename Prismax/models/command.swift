import Foundation
import SwiftData

/// A stored Prisma command (template) that can be run against any environment.
@Model
final class Command {
    @Attribute(.unique) var id: UUID
    var project: Project?

    var name: String
    /// The arguments passed after `prisma`, e.g. "migrate deploy" or "db push".
    var prismaArgs: String
    var categoryRaw: String
    /// SF Symbol name for the command icon.
    var symbolName: String
    var orderIndex: Int

    @Relationship(deleteRule: .cascade, inverse: \Guardrail.command)
    var guardrails: [Guardrail] = []

    init(
        id: UUID = UUID(),
        name: String,
        prismaArgs: String,
        category: CommandCategory = .custom,
        symbolName: String = "terminal",
        orderIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.prismaArgs = prismaArgs
        self.categoryRaw = category.rawValue
        self.symbolName = symbolName
        self.orderIndex = orderIndex
    }

    var category: CommandCategory {
        get { CommandCategory(rawValue: categoryRaw) ?? .custom }
        set { categoryRaw = newValue.rawValue }
    }
}

enum CommandCategory: String, Codable, CaseIterable, Identifiable {
    case migrate, database, generate, studio, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .migrate: "Migrations"
        case .database: "Database"
        case .generate: "Generate"
        case .studio: "Studio"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .migrate: "arrow.triangle.swap"
        case .database: "cylinder"
        case .generate: "wand.and.stars"
        case .studio: "macwindow"
        case .custom: "terminal"
        }
    }
}

/// Per-environment override of how a command may be run.
@Model
final class Guardrail {
    @Attribute(.unique) var id: UUID
    var command: Command?
    var environment: EnvProfile?

    var levelRaw: String

    init(id: UUID = UUID(), level: GuardrailLevel = .allowed) {
        self.id = id
        self.levelRaw = level.rawValue
    }

    var level: GuardrailLevel {
        get { GuardrailLevel(rawValue: levelRaw) ?? .allowed }
        set { levelRaw = newValue.rawValue }
    }
}

/// How a command may be executed against a particular environment.
enum GuardrailLevel: String, Codable, CaseIterable, Identifiable {
    /// Run immediately on click.
    case allowed
    /// Require an explicit confirmation before running.
    case confirm
    /// Never allow (button disabled with explanation).
    case blocked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .confirm: "Confirm"
        case .blocked: "Blocked"
        }
    }

    var symbol: String {
        switch self {
        case .allowed: "checkmark.circle"
        case .confirm: "exclamationmark.shield"
        case .blocked: "hand.raised"
        }
    }
}
