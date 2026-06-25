import Foundation
import SwiftData

/// Keeps every project's command list in sync with `DefaultCommands` over time.
///
/// New projects get the full default set at creation time (see `makeCommands`).
/// This seeder handles the *existing*-project case: when the default set grows
/// (a new Prisma CLI command is added, a category is introduced, …), it tops up
/// each project with the missing commands without touching commands the user has
/// already added, renamed, reordered, or deleted.
///
/// It is **additive and idempotent**:
/// - A command is considered "present" if one with the same `prismaArgs` exists,
///   so user edits to a command's name/icon are preserved.
/// - Missing commands are appended with an `orderIndex` past the current max.
///
/// Execution is gated by `commandSeedVersion` in UserDefaults so the work runs
/// only once per default-set revision. Bump `currentSeedVersion` whenever the
/// default set changes and existing projects should pick the new commands up.
enum CommandSeeder {
    /// Increment whenever `DefaultCommands.templates` changes in a way that
    /// existing projects should inherit.
    static let currentSeedVersion: Int = 1
    private static let versionKey = "commandSeedVersion"

    /// Tops up every project with any default commands it is missing.
    ///
    /// Runs at most once per `currentSeedVersion`. Safe to call on every launch.
    static func topUpIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: versionKey) < currentSeedVersion else { return }

        do {
            let projects = try context.fetch(FetchDescriptor<Project>())
            for project in projects {
                topUp(project: project)
            }
            try context.save()
        } catch {
            // Never let a seeding failure crash the app — it'll retry next launch.
            print("CommandSeeder: failed to top up commands: \(error)")
            return
        }

        defaults.set(currentSeedVersion, forKey: versionKey)
    }

    /// Inserts any default command templates whose `prismaArgs` aren't already
    /// present on `project`. Existing commands (including user edits) are left
    /// untouched.
    private static func topUp(project: Project) {
        let existingArgs = Set(project.commands.map { $0.prismaArgs })
        guard let maxIndex = project.commands.map(\.orderIndex).max() else {
            // No commands at all — shouldn't normally happen for a real project,
            // but if it does, seed the full set in template order.
            for (i, template) in DefaultCommands.templates.enumerated() {
                insert(template, into: project, orderIndex: i)
            }
            return
        }

        var nextIndex = maxIndex + 1
        for template in DefaultCommands.templates where !existingArgs.contains(template.prismaArgs) {
            insert(template, into: project, orderIndex: nextIndex)
            nextIndex += 1
        }
    }

    private static func insert(_ template: DefaultCommands.Template, into project: Project, orderIndex: Int) {
        let command = Command(
            name: template.name,
            prismaArgs: template.prismaArgs,
            category: template.category,
            symbolName: template.symbolName,
            orderIndex: orderIndex
        )
        command.project = project
        project.modelContext?.insert(command)
    }
}
