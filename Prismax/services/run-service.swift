import Foundation
import SwiftData

/// The single run path: dispatches a saved command into the integrated terminal
/// (via `TerminalManager`) and persists a `RunRecord` for History.
///
/// This replaces the old dual-path design where `PrismaRunner` ran its own
/// background `Process` with streamed output that no view ever displayed. The
/// terminal is now the only execution surface; `RunService`'s job is to record
/// what was dispatched and surface it in History for rerun.
@MainActor
@Observable
final class RunService {

    /// Commands that take over the foreground (open a server, write a file).
    /// We dispatch them but don't wait for an exit code — they're marked
    /// `.dispatched` rather than left perpetually `.running`.
    private static let foregroundCommands: Set<String> = ["studio", "format"]

    private weak var terminalManager: TerminalManager?

    func attach(_ terminalManager: TerminalManager) {
        self.terminalManager = terminalManager
    }

    // MARK: Dispatch

    /// Runs `command` against `env`: dispatches it into the project's terminal
    /// (typing the resolved invocation + Enter) and records a `RunRecord`.
    ///
    /// Honors the guardrail level: `.blocked` is a no-op, `.confirm` should be
    /// handled by the caller (this method assumes the run is approved).
    func run(
        command: Command,
        environment env: EnvProfile,
        project: Project,
        modelContext: ModelContext
    ) {
        let builder = PrismaCommandBuilder(project: project)
        let shellCommand = builder.commandString(for: command.prismaArgs)

        // Record the dispatch up front so it shows in History immediately.
        let isForeground = Self.foregroundCommands.contains(
            PrismaCommandBuilder.tokenize(command.prismaArgs).first ?? ""
        )
        let record = RunRecord(
            projectId: project.id,
            projectName: project.name,
            commandId: command.id,
            commandName: command.name,
            commandArgs: command.prismaArgs,
            environmentId: env.id,
            environmentName: env.name,
            status: isForeground ? .dispatched : .running
        )
        if isForeground {
            record.finishedAt = .now
        }
        modelContext.insert(record)
        try? modelContext.save()

        guard let terminalManager else { return }

        // For background commands, capture the exit code via the shell's OSC
        // sentinel so the record reflects the real outcome (success/failed).
        // Foreground commands (studio/format) don't return — left as .dispatched.
        if isForeground {
            terminalManager.runCommand(
                shellCommand,
                in: project,
                environment: env,
                commandTitle: command.name
            )
        } else {
            terminalManager.runCommand(
                shellCommand,
                in: project,
                environment: env,
                commandTitle: command.name,
                trackExit: true,
                onExit: { [weak modelContext] code in
                    record.exitCode = code
                    record.finishedAt = .now
                    record.status = code == 0 ? .success : .failed
                    try? modelContext?.save()
                }
            )
        }
    }

    // MARK: Rerun

    /// Re-runs the command captured by a persisted `RunRecord`, resolving the
    /// project/command/environment from the model context. Used by the History
    /// "rerun" button. Returns the record of the new run, or nil if the
    /// referenced project/environment no longer exists.
    @discardableResult
    func rerun(_ record: RunRecord, modelContext: ModelContext) -> RunRecord? {
        guard let project = fetchProject(id: record.projectId, in: modelContext),
              let envID = record.environmentId,
              let env = fetchEnvironment(id: envID, in: modelContext) else {
            return nil
        }

        // Resolve the command: by id if it still exists, else synthesize one
        // from the persisted args so a deleted command can still be rerun.
        let command: Command
        if let commandID = record.commandId,
           let found = fetchCommand(id: commandID, in: modelContext) {
            command = found
        } else {
            command = Command(name: record.commandName, prismaArgs: record.commandArgs)
        }

        run(command: command, environment: env, project: project, modelContext: modelContext)
        return record
    }

    // MARK: - Fetching

    private func fetchProject(id: UUID, in context: ModelContext) -> Project? {
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    private func fetchEnvironment(id: UUID, in context: ModelContext) -> EnvProfile? {
        let descriptor = FetchDescriptor<EnvProfile>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    private func fetchCommand(id: UUID, in context: ModelContext) -> Command? {
        let descriptor = FetchDescriptor<Command>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}
