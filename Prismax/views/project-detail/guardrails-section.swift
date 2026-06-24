import SwiftUI
import SwiftData

/// Lets the user set per-command guardrails (allow / confirm / block) for the
/// selected environment.
struct GuardrailsSection: View {
    let project: Project
    let environment: EnvProfile

    @Environment(\.modelContext) private var modelContext

    private var sortedCommands: [Command] {
        project.commands.sorted(by: { $0.orderIndex < $1.orderIndex })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 11, weight: .semibold))
                Text("GUARDRAILS")
                    .font(.micro)
                    .tracking(0.5)
                Spacer()
                Text("for \(environment.name)")
                    .font(.micro)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.tertiary)

            Text("Choose how each command may run against this environment.")
                .font(.rowSecondary)
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                ForEach(sortedCommands) { command in
                    guardrailRow(command: command)
                }
            }
        }
    }

    private func guardrailRow(command: Command) -> some View {
        let level = currentLevel(command: command)
        return HStack(spacing: 12) {
            Image(systemName: command.symbolName)
                .foregroundStyle(Theme.accent.opacity(0.85))
                .font(.system(size: 11))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(.rowPrimary)
                    .foregroundStyle(.primary)
                Text("prisma " + command.prismaArgs)
                    .font(.mono)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { level },
                set: { newLevel in setLevel(command: command, level: newLevel) }
            )) {
                ForEach(GuardrailLevel.allCases) { lvl in
                    Text(lvl.label).tag(lvl)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .labelsHidden()
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .cardStyle(cornerRadius: 8)
    }

    private func currentLevel(command: Command) -> GuardrailLevel {
        command.guardrails.first(where: { $0.environment?.id == environment.id })?.level ?? .allowed
    }

    private func setLevel(command: Command, level: GuardrailLevel) {
        if let existing = command.guardrails.first(where: { $0.environment?.id == environment.id }) {
            if level == .allowed {
                modelContext.delete(existing)
            } else {
                existing.level = level
            }
        } else if level != .allowed {
            let guardrail = Guardrail(level: level)
            guardrail.command = command
            guardrail.environment = environment
            modelContext.insert(guardrail)
        }
        try? modelContext.save()
    }
}
