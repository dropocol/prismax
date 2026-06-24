import SwiftUI

/// Owns the live terminal processes, one per project. The detail column shows
/// the selected project's terminal; switching projects switches terminals.
/// Environment variables (Keychain + .env file) for the active environment are
/// preloaded into the shell when it starts.
@MainActor
@Observable
final class TerminalManager {
    /// projectID → live terminal process
    private(set) var processes: [UUID: TerminalProcess] = [:]

    /// Returns the terminal for `project`, creating it on first access.
    /// Note: a freshly created process is NOT spawned yet — callers must go
    /// through `ensureRunning(...)` before reading/writing it.
    func terminal(for project: Project) -> TerminalProcess {
        if let existing = processes[project.id] {
            return existing
        }
        let process = TerminalProcess()
        processes[project.id] = process
        return process
    }

    /// Ensures the terminal for `project` is spawned and running, returning the
    /// process and whether a fresh spawn happened. Reuses the same object
    /// instance (re-keyed into the dictionary on first creation) so views that
    /// hold a reference to it stay bound to the live shell — only `restart`
    /// ever swaps in a brand-new process.
    @discardableResult
    func ensureRunning(
        for project: Project,
        environment env: EnvProfile
    ) -> (process: TerminalProcess, didSpawn: Bool) {
        let process = terminal(for: project)
        if process.isRunning { return (process, false) }

        // Same object, fresh spawn. spawn() re-points masterFD/childPID at the
        // new PTY, and restarts the read loop. The view keeps its reference and
        // continues to receive output via the shared TerminalProcess instance.
        let envVars = PrismaRunnerStatic.resolveEnvironment(project: project, environment: env)
        do {
            // Spawn in the prisma command dir (e.g. a monorepo's `packages/db`)
            // so Prisma finds schema.prisma via its default lookup.
            try process.spawn(workingDirectory: project.commandDirectory, environment: envVars)
        } catch {
            print("Terminal spawn failed: \(error)")
        }
        return (process, true)
    }

    /// Spawns (or restarts) the terminal for `project`, loading env vars from
    /// the given environment (Keychain + .env file).
    func start(for project: Project, environment env: EnvProfile) {
        _ = ensureRunning(for: project, environment: env)
    }

    /// Restarts the terminal (kills the old shell, spawns a fresh one).
    func restart(for project: Project, environment env: EnvProfile) {
        processes[project.id]?.terminate()
        processes.removeValue(forKey: project.id)
        start(for: project, environment: env)
    }

    /// Kills the terminal for a project (used when the project is removed).
    func kill(for projectID: UUID) {
        processes[projectID]?.terminate()
        processes.removeValue(forKey: projectID)
    }

    /// Runs a command in the project's terminal by typing it + Enter. Used by
    /// the play-button commands — they route through the real terminal so the
    /// output, history, and interactivity all live in one place.
    func runCommand(_ command: String, in project: Project, environment env: EnvProfile) {
        // Ensure the shell is up. ensureRunning spawns synchronously, so by the
        // time it returns the process is either live or spawning failed.
        let (process, didSpawn) = ensureRunning(for: project, environment: env)

        guard process.isRunning else {
            // Spawning failed — surface it visibly instead of swallowing it.
            print("⚠️ Prismax: terminal is not running; command not sent: \(command)")
            return
        }

        if didSpawn {
            // The shell just started (login + interactive zsh sources .zprofile
            // AND .zshrc before printing a prompt). Give it a moment to be ready
            // to receive input, otherwise the typed command can race the startup
            // banner and get mangled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak process] in
                process?.send(command + "\n")
            }
        } else {
            process.send(command + "\n")
        }
    }
}
