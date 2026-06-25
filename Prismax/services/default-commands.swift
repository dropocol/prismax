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
        // Setup
        .init(name: "Init", prismaArgs: "init", category: .setup, symbolName: "plus.app"),
        .init(name: "Bootstrap", prismaArgs: "bootstrap", category: .setup, symbolName: "shippingbox"),
        .init(name: "Dev", prismaArgs: "dev", category: .setup, symbolName: "play.circle"),

        // Migrations
        .init(name: "Migrate Dev", prismaArgs: "migrate dev", category: .migrate, symbolName: "hammer"),
        .init(name: "Migrate Deploy", prismaArgs: "migrate deploy", category: .migrate, symbolName: "arrow.up.square"),
        .init(name: "Migrate Status", prismaArgs: "migrate status", category: .migrate, symbolName: "info.circle"),
        .init(name: "Migrate Reset", prismaArgs: "migrate reset", category: .migrate, symbolName: "arrow.counterclockwise"),
        .init(name: "Migrate Resolve", prismaArgs: "migrate resolve", category: .migrate, symbolName: "checkmark.circle.badge.questionmark"),
        .init(name: "Migrate Diff", prismaArgs: "migrate diff", category: .migrate, symbolName: "arrow.left.and.right.square"),

        // Database
        .init(name: "DB Push", prismaArgs: "db push", category: .database, symbolName: "arrowshape.up.fill"),
        .init(name: "DB Pull (Introspect)", prismaArgs: "db pull", category: .database, symbolName: "arrowshape.down.fill"),
        .init(name: "DB Seed", prismaArgs: "db seed", category: .database, symbolName: "leaf"),
        .init(name: "DB Execute", prismaArgs: "db execute", category: .database, symbolName: "play"),

        // Generate
        .init(name: "Generate Client", prismaArgs: "generate", category: .generate, symbolName: "wand.and.stars"),

        // Schema
        .init(name: "Validate Schema", prismaArgs: "validate", category: .schema, symbolName: "checkmark.shield"),
        .init(name: "Format Schema", prismaArgs: "format", category: .schema, symbolName: "text.alignleft"),

        // Studio
        .init(name: "Open Studio", prismaArgs: "studio", category: .studio, symbolName: "macwindow"),

        // Postgres
        .init(name: "Postgres Link", prismaArgs: "postgres link", category: .postgres, symbolName: "link"),

        // Platform
        .init(name: "Platform Status", prismaArgs: "platform status", category: .platform, symbolName: "serverlever"),

        // MCP
        .init(name: "Start MCP Server", prismaArgs: "mcp", category: .mcp, symbolName: "network"),

        // Diagnostics
        .init(name: "Version", prismaArgs: "version", category: .diagnostics, symbolName: "info.circle"),
        .init(name: "Debug", prismaArgs: "debug", category: .diagnostics, symbolName: "ladybug"),
        .init(name: "Telemetry", prismaArgs: "telemetry", category: .diagnostics, symbolName: "chart.bar"),
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
