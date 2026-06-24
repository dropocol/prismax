import SwiftUI

/// One interactive terminal session belonging to a project. In "persistent"
/// mode there's a single session per project; in "per-command" mode each run
/// opens a new session (a tab).
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id: UUID
    /// The underlying PTY/shell. Observable, so views bound to it update live.
    let process: TerminalProcess
    /// Human-readable tab title (command name, or "Shell" for the default).
    var title: String
    let createdAt: Date

    init(id: UUID = UUID(), process: TerminalProcess, title: String, createdAt: Date = .now) {
        self.id = id
        self.process = process
        self.title = title
        self.createdAt = createdAt
    }
}

/// Owns the live terminal sessions, one-or-more per project. The detail column
/// shows the selected project's active session; switching projects switches the
/// shown terminal. Environment variables (Keychain + .env file) for the active
/// environment are preloaded into the shell when it starts.
@MainActor
@Observable
final class TerminalManager {
    /// projectID → ordered sessions (newest first). The first element is the
    /// active one shown in the terminal panel.
    private(set) var sessionsByProject: [UUID: [TerminalSession]] = [:]

    private static let terminalModeKey = "terminalMode"

    /// Current terminal mode from user settings.
    private var terminalMode: TerminalMode {
        TerminalMode(rawValue: UserDefaults.standard.string(forKey: Self.terminalModeKey) ?? "")
            ?? .persistent
    }

    // MARK: Read

    /// All sessions for a project (newest first). Empty if none.
    func sessions(for project: Project) -> [TerminalSession] {
        sessionsByProject[project.id] ?? []
    }

    /// The session currently shown for a project (the first/newest), or nil.
    func activeSession(for project: Project) -> TerminalSession? {
        sessions(for: project).first
    }

    /// The active session's process — the one views should bind to. Creates a
    /// default "Shell" session on first access (used by the persistent mode and
    /// by the panel on appear) so the panel always has something to show.
    func terminal(for project: Project) -> TerminalProcess {
        if let session = activeSession(for: project) {
            return session.process
        }
        // No session yet: create the default one. It isn't spawned until
        // ensureRunning/start is called.
        return openSession(for: project, title: "Shell").process
    }

    // MARK: Spawn / lifecycle

    /// Ensures the active session's process is spawned and running, returning
    /// the process and whether a fresh spawn happened.
    @discardableResult
    func ensureRunning(
        for project: Project,
        environment env: EnvProfile
    ) -> (process: TerminalProcess, didSpawn: Bool) {
        let process = terminal(for: project)
        if process.isRunning { return (process, false) }

        let envVars = PrismaRunnerStatic.resolveEnvironment(project: project, environment: env)
        do {
            try process.spawn(workingDirectory: project.commandDirectory, environment: envVars)
        } catch {
            print("Terminal spawn failed: \(error)")
        }
        return (process, true)
    }

    /// Spawns (or restarts) the active terminal for `project`.
    func start(for project: Project, environment env: EnvProfile) {
        _ = ensureRunning(for: project, environment: env)
    }

    /// Restarts the active terminal (kills the old shell, spawns a fresh one).
    func restart(for project: Project, environment env: EnvProfile) {
        guard let session = activeSession(for: project) else {
            start(for: project, environment: env)
            return
        }
        session.process.terminate()
        let envVars = PrismaRunnerStatic.resolveEnvironment(project: project, environment: env)
        do {
            try session.process.spawn(workingDirectory: project.commandDirectory, environment: envVars)
        } catch {
            print("Terminal spawn failed: \(error)")
        }
    }

    /// Kills all sessions for a project (used when the project is removed).
    func kill(for projectID: UUID) {
        for session in sessionsByProject[projectID] ?? [] {
            session.process.terminate()
        }
        sessionsByProject.removeValue(forKey: projectID)
    }

    // MARK: Tabs

    /// Opens a new session/tab for `project`, makes it active, returns it. Not
    /// spawned — callers spawn via ensureRunning/start when needed.
    @discardableResult
    func openSession(for project: Project, title: String) -> TerminalSession {
        let session = TerminalSession(process: TerminalProcess(), title: title)
        var list = sessionsByProject[project.id] ?? []
        list.insert(session, at: 0)
        sessionsByProject[project.id] = list
        return session
    }

    /// Makes the given session the active (first) one for its project.
    func makeActive(project: Project, session sessionID: UUID) {
        guard var list = sessionsByProject[project.id],
              let idx = list.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = list.remove(at: idx)
        list.insert(session, at: 0)
        sessionsByProject[project.id] = list
    }

    /// Closes a session/tab (terminates its shell, removes it). The most recent
    /// remaining session becomes active. Does nothing if it's the only session.
    func closeSession(project: Project, session sessionID: UUID) {
        guard var list = sessionsByProject[project.id], !list.isEmpty else { return }
        guard let idx = list.firstIndex(where: { $0.id == sessionID }) else { return }
        // Keep at least one session alive (the persistent shell).
        if list.count == 1 {
            // Closing the last tab: reset its shell instead of removing.
            list[idx].process.terminate()
            sessionsByProject[project.id] = list
            return
        }
        list[idx].process.terminate()
        list.remove(at: idx)
        sessionsByProject[project.id] = list
    }

    // MARK: Run command

    /// Runs a command in the project's terminal. Behavior depends on terminal
    /// mode: in `.persistent` it types into the shared terminal; in `.perCommand`
    /// it opens a fresh tab for this run and types into that.
    func runCommand(
        _ command: String,
        in project: Project,
        environment env: EnvProfile,
        commandTitle: String? = nil
    ) {
        let process: TerminalProcess
        let didSpawn: Bool

        if terminalMode == .perCommand {
            // Open a new tab titled after the command (or "Shell"), then ensure
            // it's running before typing into it.
            let session = openSession(for: project, title: commandTitle ?? "Run")
            let result = ensureRunning(process: session.process, for: project, environment: env)
            process = result.process
            didSpawn = result.didSpawn
        } else {
            let result = ensureRunning(for: project, environment: env)
            process = result.process
            didSpawn = result.didSpawn
        }

        guard process.isRunning else {
            print("⚠️ Prismax: terminal is not running; command not sent: \(command)")
            return
        }

        if didSpawn {
            // Give a freshly-spawned login+interactive shell a moment to be
            // ready before typing, so the command doesn't race the startup banner.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak process] in
                process?.send(command + "\n")
            }
        } else {
            process.send(command + "\n")
        }
    }

    /// Ensures a specific process is spawned (used when opening a tab with an
    /// already-created process).
    private func ensureRunning(
        process: TerminalProcess,
        for project: Project,
        environment env: EnvProfile
    ) -> (process: TerminalProcess, didSpawn: Bool) {
        if process.isRunning { return (process, false) }
        let envVars = PrismaRunnerStatic.resolveEnvironment(project: project, environment: env)
        do {
            try process.spawn(workingDirectory: project.commandDirectory, environment: envVars)
        } catch {
            print("Terminal spawn failed: \(error)")
        }
        return (process, true)
    }
}
