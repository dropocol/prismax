import Foundation
import SwiftUI
import SwiftData

/// Converts a schema path (relative to the project root) into one relative to
/// the command dir, so it resolves correctly when the process runs from
/// `commandDirectory` instead of the project root. If `prismaDir` is empty
/// (running from root) the path is returned unchanged.
///
/// e.g. prismaDir="packages/db", schemaPath="packages/db/prisma/schema.prisma"
///      → "prisma/schema.prisma"
private func schemaPathRelative(toCommandDir prismaDir: String, schemaPath: String) -> String {
    guard !prismaDir.isEmpty else { return schemaPath }
    let prefix = prismaDir.hasSuffix("/") ? prismaDir : prismaDir + "/"
    if schemaPath.hasPrefix(prefix) {
        return String(schemaPath.dropFirst(prefix.count))
    }
    return schemaPath
}

/// Builds and spawns a Prisma process with environment variables loaded from the
/// Keychain. Streams stdout + stderr line-by-line to the UI and persists a RunRecord.
///
/// Holds a **session list** of all runs (live and finished) so the terminal panel
/// can keep showing a run's output after it completes, and support multiple
/// concurrent/sequential runs.
@MainActor
@Observable
final class PrismaRunner {
    /// All run sessions, newest first. Finished sessions remain here until cleared.
    private(set) var sessions: [RunHandle] = []

    /// The session currently displayed in the terminal panel.
    private(set) var activeSessionID: UUID?

    /// Convenience: the visible session (if any).
    var visibleSession: RunHandle? {
        sessions.first(where: { $0.id == activeSessionID })
    }

    /// True if any session is still running (for the header indicator).
    var hasRunningSession: Bool { sessions.contains(where: { $0.isRunning }) }

    private var handles: [UUID: RunHandle] = [:]
    private var collectors: [UUID: OutputCollector] = [:]
    private var processes: [UUID: Process] = [:]

    // MARK: Run

    /// Builds and launches a process for `command` against `environment`.
    /// - Returns: The handle for the newly started session.
    @discardableResult
    func run(
        command: Command,
        environment env: EnvProfile,
        project: Project,
        modelContext: ModelContext
    ) throws -> RunHandle {
        // The full command the user typed, e.g. `pnpm exec prisma migrate dev`.
        let (executable, baseArgs) = project.packageManager.prismaInvocation
        let prismaArgs = command.prismaArgs
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        var fullArgs = baseArgs + prismaArgs
        if UserDefaults.standard.bool(forKey: "includeSchemaArg"), !project.schemaPath.isEmpty {
            // `schemaPath` is relative to the project root, but the process runs
            // from `commandDirectory` (which may be a subfolder in a monorepo).
            // Strip the prismaDir prefix so the path resolves from the cwd.
            let schemaFromCwd = schemaPathRelative(toCommandDir: project.prismaDir ?? "",
                                                   schemaPath: project.schemaPath)
            fullArgs += ["--schema", schemaFromCwd]
        }

        // GUI apps inherit a minimal PATH and can't find pnpm/npx/bunx/yarn.
        // Run through an interactive login shell so BOTH .zprofile AND .zshrc
        // are sourced — that's where nvm, fnm, volta, pnpm's installer, bun,
        // and deno typically add themselves to PATH.
        let commandString = ([executable] + fullArgs).map { shellQuote($0) }.joined(separator: " ")

        // Merge Keychain env vars over the login shell's resolved environment.
        // We export each secret explicitly so it takes precedence.
        let secretExports = env.variables.compactMap { variable -> String? in
            guard let value = try? KeychainService.get(account: variable.keychainAccount) else { return nil }
            return "export \(variable.key)=\(shellQuote(value));"
        }.joined(separator: " ")
        let shellCommand = secretExports.isEmpty ? commandString : "\(secretExports) \(commandString)"

        let process = Process()
        // Run from the prisma command dir (e.g. `packages/db` in a monorepo) so
        // Prisma finds schema.prisma via its default lookup.
        process.currentDirectoryURL = URL(fileURLWithPath: project.commandDirectory)
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -l: login (sources .zprofile)  -i: interactive (sources .zshrc)
        // -c: run the following command
        process.arguments = ["-lic", shellCommand]
        // Inherit the base environment (HOME etc.); the shell sets the rest.
        process.environment = ["HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Persist a record up front.
        let record = RunRecord(
            projectId: project.id,
            projectName: project.name,
            commandId: command.id,
            commandName: command.name,
            commandArgs: command.prismaArgs,
            environmentId: env.id,
            environmentName: env.name
        )
        modelContext.insert(record)

        let handle = RunHandle(
            recordID: record.id,
            displayName: command.name,
            commandArgs: command.prismaArgs,
            environmentName: env.name,
            projectName: project.name
        )
        let collector = OutputCollector(recordID: record.id)

        sessions.insert(handle, at: 0)
        handles[record.id] = handle
        collectors[record.id] = collector
        activeSessionID = handle.id

        let headerLine = "$ \(commandString)"
        handle.appendSystemLine(headerLine)
        collector.append(headerLine + "\n")

        do {
            try process.run()
            handle.isRunning = true
            handle.processID = process.processIdentifier
            processes[record.id] = process

            let recordID = record.id
            Task { @MainActor in
                await StreamReader.read(
                    process: process,
                    stdout: stdoutPipe,
                    stderr: stderrPipe,
                    onLine: { line, kind in
                        switch kind {
                        case .stdout: handle.appendStdoutLine(line)
                        case .stderr: handle.appendStderrLine(line)
                        }
                        collector.append(line + "\n", modelContext: modelContext)
                    },
                    onFinish: { code in
                        self.finish(recordID: recordID, exitCode: code, modelContext: modelContext)
                    }
                )
            }
        } catch {
            handle.appendStderrLine("⚠️ Failed to launch: \(error.localizedDescription)")
            collector.append("⚠️ Failed to launch: \(error.localizedDescription)\n")
            finish(recordID: record.id, exitCode: -1, modelContext: modelContext)
        }

        return handle
    }

    // MARK: Selection

    /// Makes `session` the one shown in the terminal panel.
    func show(_ session: RunHandle) {
        if sessions.contains(where: { $0.id == session.id }) {
            activeSessionID = session.id
        }
    }

    /// Shows the most recent run (live or finished).
    func showLatest() {
        activeSessionID = sessions.first?.id
    }

    /// Opens a persisted RunRecord's output as a read-only finished session in
    /// the terminal panel. Used when revisiting a past run from History.
    func showRecord(_ record: RunRecord) {
        // If already open, just select it.
        if let existing = sessions.first(where: { $0.recordID == record.id }) {
            activeSessionID = existing.id
            return
        }
        let handle = RunHandle(
            recordID: record.id,
            displayName: record.commandName,
            commandArgs: record.commandArgs,
            environmentName: record.environmentName,
            projectName: record.projectName,
            startedAt: record.startedAt
        )
        handle.status = record.status
        handle.exitCode = record.exitCode
        handle.finishedAt = record.finishedAt
        handle.isRunning = false
        for line in record.output.split(separator: "\n", omittingEmptySubsequences: false) {
            handle.appendStdoutLine(String(line))
        }
        sessions.insert(handle, at: 0)
        handles[record.id] = handle
        activeSessionID = handle.id
    }

    // MARK: Cancel

    func cancel(sessionID: UUID) {
        guard let handle = handles[sessionID], handle.isRunning else { return }
        handle.status = .canceled
        terminate(pid: handle.processID)
        // The StreamReader's onFinish will fire with the real exit code shortly;
        // we mark the final status here so it reads as "canceled".
    }

    private func terminate(pid: Int32) {
        kill(pid, SIGTERM)
    }

    // MARK: Rerun

    /// Re-runs the command captured by a persisted RunRecord, resolving the
    /// project/command/environment from the model context. Used by the History
    /// and OutputDetailView "rerun" buttons.
    @discardableResult
    func rerun(_ record: RunRecord, modelContext: ModelContext) throws -> RunHandle? {
        let projectID = record.projectId
        let projectDescriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })
        guard let project = try? modelContext.fetch(projectDescriptor).first else { return nil }

        // Resolve the command: by id if it still exists, else synthesize one
        // from the persisted args so a deleted command can still be rerun.
        let command: Command
        if let commandID = record.commandId {
            let commandDescriptor = FetchDescriptor<Command>(predicate: #Predicate { $0.id == commandID })
            if let found = try? modelContext.fetch(commandDescriptor).first {
                command = found
            } else {
                command = Command(name: record.commandName, prismaArgs: record.commandArgs)
            }
        } else {
            command = Command(name: record.commandName, prismaArgs: record.commandArgs)
        }

        // Resolve the environment: by id if it still exists.
        guard let envID = record.environmentId else { return nil }
        let envDescriptor = FetchDescriptor<EnvProfile>(predicate: #Predicate { $0.id == envID })
        guard let env = try? modelContext.fetch(envDescriptor).first else { return nil }

        return try run(command: command, environment: env, project: project, modelContext: modelContext)
    }

    // MARK: Clear / close

    /// Removes a finished session from the panel. Running sessions cannot be cleared.
    func close(sessionID: UUID) {
        guard let handle = handles[sessionID], !handle.isRunning else { return }
        sessions.removeAll(where: { $0.id == sessionID })
        handles.removeValue(forKey: sessionID)
        collectors.removeValue(forKey: sessionID)
        processes.removeValue(forKey: sessionID)
        if activeSessionID == sessionID {
            activeSessionID = sessions.first?.id
        }
    }

    /// Clears all finished sessions.
    func clearFinished() {
        let finished = sessions.filter { !$0.isRunning }.map(\.id)
        for id in finished {
            handles.removeValue(forKey: id)
            collectors.removeValue(forKey: id)
            processes.removeValue(forKey: id)
        }
        sessions.removeAll(where: { !$0.isRunning })
        if let active = activeSessionID, !sessions.contains(where: { $0.id == active }) {
            activeSessionID = sessions.first?.id
        }
    }

    // MARK: Finish

    func finish(recordID: UUID, exitCode: Int, modelContext: ModelContext) {
        guard let handle = handles[recordID] else { return }
        // Preserve a canceled status if the user canceled before exit.
        if handle.status != .canceled {
            handle.status = exitCode == 0 ? .success : .failed
        }
        handle.isRunning = false
        handle.exitCode = exitCode
        handle.finishedAt = .now

        // Flush the final buffer into the persisted record.
        let buffer = collectors[recordID]?.buffer ?? handle.fullText
        if let record = fetchRecord(id: recordID, context: modelContext) {
            record.exitCode = exitCode
            record.status = handle.status
            record.finishedAt = .now
            record.output = buffer
        }
        try? modelContext.save()
        collectors[recordID]?.markClean()

        handle.appendSystemLine("— exit \(exitCode) —")
    }

    // MARK: Environment resolution

    /// Reads each variable's value from the Keychain and builds the full
    /// environment dictionary. Used by SchemaService for `migrate status`.
    func resolveEnvironment(project: Project, environment env: EnvProfile) -> [String: String] {
        PrismaRunnerStatic.resolveEnvironment(project: project, environment: env)
    }

    // MARK: Helpers

    private func fetchRecord(id: UUID, context: ModelContext) -> RunRecord? {
        let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}

// MARK: - StreamReader

/// Reads combined stdout/stderr from a `Process`'s pipes and forwards complete
/// lines to the main actor. All pipe access happens on a background task so no
/// non-Sendable `Pipe` crosses an isolation boundary.
enum StreamReader {
    enum LineKind { case stdout, stderr }

    static func read(
        process: Process,
        stdout: Pipe,
        stderr: Pipe,
        onLine: @escaping @MainActor (String, LineKind) -> Void,
        onFinish: @escaping @MainActor (Int) -> Void
    ) async {
        let stdoutTask = Task { await forward(handle: stdout.fileHandleForReading, kind: .stdout, onLine: onLine) }
        let stderrTask = Task { await forward(handle: stderr.fileHandleForReading, kind: .stderr, onLine: onLine) }

        _ = await stdoutTask.value
        _ = await stderrTask.value

        process.waitUntilExit()
        await MainActor.run {
            onFinish(Int(process.terminationStatus))
        }
    }

    private static func forward(
        handle: FileHandle,
        kind: LineKind,
        onLine: @escaping @MainActor (String, LineKind) -> Void
    ) async {
        let buffer = LineBuffer()
        while true {
            let data: Data
            do {
                if let read = try handle.read(upToCount: 4096) {
                    data = read
                } else {
                    data = Data()
                }
            } catch {
                break
            }
            if data.isEmpty {
                if let leftover = buffer.flush(), !leftover.isEmpty {
                    await MainActor.run { onLine(leftover, kind) }
                }
                break
            }
            for line in buffer.append(data) {
                await MainActor.run { onLine(line, kind) }
            }
        }
    }
}

// MARK: - RunHandle

/// A live handle to a running or finished command, observed by the UI.
@MainActor
@Observable
final class RunHandle: Identifiable {
    let id: UUID
    let recordID: UUID
    let displayName: String
    let commandArgs: String
    let environmentName: String
    let projectName: String
    let startedAt: Date

    /// Aggregated output lines for display.
    private(set) var lines: [RunLine] = []
    var isRunning: Bool = false
    var processID: Int32 = 0
    var exitCode: Int?
    var status: RunStatus = .running
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        recordID: UUID,
        displayName: String,
        commandArgs: String,
        environmentName: String,
        projectName: String,
        startedAt: Date = .now
    ) {
        self.id = id
        self.recordID = recordID
        self.displayName = displayName
        self.commandArgs = commandArgs
        self.environmentName = environmentName
        self.projectName = projectName
        self.startedAt = startedAt
    }

    func appendStdoutLine(_ text: String) { lines.append(.init(text: text, kind: .stdout)) }
    func appendStderrLine(_ text: String) { lines.append(.init(text: text, kind: .stderr)) }
    func appendSystemLine(_ text: String) { lines.append(.init(text: text, kind: .system)) }

    var fullText: String { lines.map(\.text).joined(separator: "\n") }

    var durationLabel: String {
        let end = finishedAt ?? .now
        let secs = end.timeIntervalSince(startedAt)
        if secs < 1 { return String(format: "%.0fms", secs * 1000) }
        if secs < 60 { return String(format: "%.1fs", secs) }
        return String(format: "%.1fm", secs / 60)
    }
}

struct RunLine: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let kind: LineKind

    enum LineKind { case stdout, stderr, system }
}

// MARK: - OutputCollector

/// Accumulates output for persistence into the RunRecord without touching
/// SwiftData on every line.
@MainActor
final class OutputCollector {
    let recordID: UUID
    private(set) var buffer: String = ""
    private var dirty: Bool = false
    private var lastFlush: Date = .now

    init(recordID: UUID) { self.recordID = recordID }

    func append(_ text: String, modelContext: ModelContext? = nil) {
        buffer += text
        dirty = true
        if Date().timeIntervalSince(lastFlush) > 1.0, let modelContext {
            flush(modelContext: modelContext)
        }
    }

    func flush(modelContext: ModelContext) {
        guard dirty else { return }
        dirty = false
        lastFlush = .now
        let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == recordID })
        if let record = try? modelContext.fetch(descriptor).first {
            record.output = buffer
        }
    }

    func markClean() { dirty = false }
}

// MARK: - LineBuffer

/// Splits an incoming byte stream into newline-delimited lines, preserving a
/// trailing partial line until the next chunk arrives.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    @discardableResult
    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let idx = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: 0..<idx)
            pending.removeSubrange(0...idx)
            if let s = String(data: lineData, encoding: .utf8) { lines.append(s) }
        }
        return lines
    }

    func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let s = String(data: pending, encoding: .utf8)
        pending.removeAll()
        return s
    }
}
