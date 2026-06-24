import Foundation

/// Provides the default set of Prisma commands created when a new project is added.
enum DefaultCommands {

    struct Template {
        let name: String
        let prismaArgs: String
        let category: CommandCategory
        let symbolName: String
    }

    static let templates: [Template] = [
        // Migrations
        .init(name: "Migrate Dev", prismaArgs: "migrate dev", category: .migrate, symbolName: "hammer"),
        .init(name: "Migrate Deploy", prismaArgs: "migrate deploy", category: .migrate, symbolName: "arrow.up.square"),
        .init(name: "Migrate Status", prismaArgs: "migrate status", category: .migrate, symbolName: "info.circle"),
        .init(name: "Migrate Reset", prismaArgs: "migrate reset", category: .migrate, symbolName: "arrow.counterclockwise"),
        .init(name: "Migrate Resolve", prismaArgs: "migrate resolve", category: .migrate, symbolName: "checkmark.circle.badge.questionmark"),

        // Database
        .init(name: "DB Push", prismaArgs: "db push", category: .database, symbolName: "arrowshape.up.fill"),
        .init(name: "DB Pull (Introspect)", prismaArgs: "db pull", category: .database, symbolName: "arrowshape.down.fill"),
        .init(name: "DB Seed", prismaArgs: "db seed", category: .database, symbolName: "leaf"),
        .init(name: "DB Execute", prismaArgs: "db execute", category: .database, symbolName: "play"),

        // Generate
        .init(name: "Generate Client", prismaArgs: "generate", category: .generate, symbolName: "wand.and.stars"),
        .init(name: "Validate Schema", prismaArgs: "validate", category: .generate, symbolName: "checkmark.shield"),

        // Studio
        .init(name: "Open Studio", prismaArgs: "studio", category: .studio, symbolName: "macwindow"),
        .init(name: "Format Schema", prismaArgs: "format", category: .studio, symbolName: "text.alignleft"),
    ]

    /// Creates a fresh set of `Command` instances for a new project.
    static func makeCommands() -> [Command] {
        templates.enumerated().map { index, template in
            Command(
                name: template.name,
                prismaArgs: template.prismaArgs,
                category: template.category,
                symbolName: template.symbolName,
                orderIndex: index
            )
        }
    }
}
