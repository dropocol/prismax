import Foundation

/// A shell command line plus optional extra environment, executed via the
/// user's login shell with common tool directories prepended to PATH.
struct ShellCommand {
    /// The full command string executed as `login-shell -l -c <commandLine>`.
    let commandLine: String
    /// The CLI tool name (first token of `commandLine`), used for a pre-flight
    /// availability check so missing tools surface a clear error. Derived
    /// automatically from `commandLine`.
    var tool: String?
    /// Extra environment variables overlaid on the process's inherited env so
    /// secrets (e.g. `MYSQL_PWD`, resolved `DATABASE_URL`) never appear on the
    /// command line.
    var extraEnvironment: [String: String] = [:]

    init(commandLine: String, extraEnvironment: [String: String] = [:]) {
        self.commandLine = commandLine
        self.tool = ShellCommand.firstToken(of: commandLine)
        self.extraEnvironment = extraEnvironment
    }

    /// Extracts the first whitespace-delimited token (the tool name).
    private static func firstToken(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let end = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return trimmed.isEmpty ? nil : trimmed
        }
        let tok = String(trimmed[..<end])
        return tok.isEmpty ? nil : tok
    }
}

/// Executes `ShellCommand`s via the user's **default login shell** with common
/// CLI-tool directories prepended to PATH.
///
/// A GUI app inherits only a minimal PATH (`/usr/bin:/bin:…`), and a login
/// non-interactive zsh only sources `/etc/paths.d` + `.zprofile` — neither of
/// which includes Homebrew (`/opt/homebrew/bin`), Postgres.app, or `libpq` on a
/// typical setup (those are added in the interactive `.zshrc`). `ShellRunner`
/// solves two problems:
///
/// 1. **PATH resolution** — it uses the user's own configured login shell
///    (bash/fish/zsh via `getpwuid`) so each user's profile PATH loads, AND it
///    prepends well-known tool directories that exist on disk, so tools resolve
///    regardless of how the shell is configured.
/// 2. **Missing-tool errors** — before spawning, it pre-flights the command's
///    tool via `which`; if missing it calls `onToolMissing(tool:)` so the caller
///    can raise an actionable error (with install hints) instead of a cryptic
///    "Exit 127: command not found".
///
/// The shell runs non-interactively (`-l -c`) so interactive banners/prompts
/// never leak into captured output.
enum ShellRunner {
    /// Directories where DB CLI tools commonly live, prepended to PATH when they
    /// exist on disk. Kept here (not in a DB-specific type) so the runner stays
    /// the single owner of PATH augmentation.
    private static let toolPathDirs: [String] = [
        "/opt/homebrew/bin",                                       // Apple Silicon Homebrew
        "/opt/homebrew/opt/libpq/bin",                             // Homebrew libpq (pg tools)
        "/usr/local/bin",                                          // Intel Homebrew
        "/usr/local/opt/libpq/bin",
        "/Applications/Postgres.app/Contents/Versions/Latest/bin", // Postgres.app
        "/Library/PostgreSQL/17/bin",                              // EnterpriseDB installers
        "/Library/PostgreSQL/16/bin",
        "/Library/PostgreSQL/15/bin",
        "/Library/PostgreSQL/14/bin",
    ]

    /// Bootstrap lines prepended to every command so Node version managers
    /// (nvm, fnm, volta) and Bun add their bin dirs to PATH. Each line is
    /// guarded to no-op when the tool isn't installed, so this is safe to run
    /// ahead of any command (DB CLIs included).
    ///
    /// Why both this AND `toolPathDirs`: Homebrew installs drop `node`/`npx`
    /// directly into `/opt/homebrew/bin`, which `toolPathDirs` covers. But nvm
    /// and fnm keep each Node version in `~/.nvm/versions/node/vX/bin` — a
    /// directory that only exists once the manager is *sourced*, which is what
    /// these lines do. Without sourcing, `npx` can resolve (via Homebrew) while
    /// `node` does not, and `npx`'s `#!/usr/bin/env node` shebang then fails
    /// with `env: node: No such file or directory` (exit 127).
    private static let versionManagerBootstrap = """
    [ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" 2>/dev/null
    command -v fnm >/dev/null 2>&1 && eval "$(fnm env --shell zsh 2>/dev/null)"
    [ -s "$HOME/.volta/bin" ] && export PATH="$HOME/.volta/bin:$PATH"
    [ -s "$HOME/.bun/bin" ] && export PATH="$HOME/.bun/bin:$PATH"
    """

    /// Executes `command`, returning its combined stdout+stderr.
    ///
    /// - Parameters:
    ///   - directory: Working directory to run in. When nil, the process
    ///     inherits the app's cwd — fine for tools that don't care (e.g. a DB
    ///     CLI pointed at a URL). Pass a project's command dir when the tool
    ///     resolves files relative to cwd (Prisma's schema lookup), e.g. a
    ///     monorepo package directory.
    ///   - timeout: Max seconds to wait before terminating the process. Guards
    ///     against commands that hang indefinitely (e.g. `prisma migrate status`
    ///     trying to reach an offline database). `nil` = wait forever.
    ///   - onToolMissing: invoked (synchronously) when the command's tool
    ///     isn't on PATH; the closure should return/throw the caller-specific
    ///     error to raise. This keeps `ShellRunner` decoupled from any particular
    ///     domain's error types.
    @discardableResult
    static func run(
        command: ShellCommand,
        directory: String? = nil,
        timeout: TimeInterval? = nil,
        onToolMissing: (String) throws -> Void = { _ in }
    ) async throws -> String {
        let env = resolvedEnvironment(overlaying: command.extraEnvironment)

        // Pre-flight: confirm the tool resolves on PATH so we can surface a
        // helpful error rather than "exit 127".
        if let tool = command.tool {
            try ensureToolAvailable(tool, in: env, onMissing: onToolMissing)
        }

        let (shell, args) = loginShell(for: command.commandLine)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = args
        process.environment = env
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch {
            throw ShellRunnerError.launchFailed(error.localizedDescription)
        }

        // Enforce the timeout by terminating the process if it outlives `timeout`.
        // The read below then unblocks and the captured partial output is returned.
        var timedOut = false
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                }
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if timedOut {
            throw ShellRunnerError.timedOut(seconds: timeout ?? 0)
        }
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw ShellRunnerError.launchFailed("Exit \(process.terminationStatus): \(output)")
        }
        return output
    }

    /// Streaming variant of `run`: executes `command` and emits its combined
    /// stdout+stderr as `Data` chunks **as they arrive**, so callers can show
    /// live progress (e.g. a restore log) instead of waiting for the whole
    /// output at once. The stream:
    ///   - yields `Data` chunks while the process runs,
    ///   - finishes (returns) when the process exits,
    ///   - throws `ShellRunnerError` on a non-zero exit (with the full output
    ///     accumulated so far) or a timeout.
    ///
    /// Used by long-running, output-rich commands like `pg_restore -v` /
    /// `psql -f`, where the buffered `run` would leave the UI blind until exit.
    static func runStreaming(
        command: ShellCommand,
        directory: String? = nil,
        timeout: TimeInterval? = nil,
        onToolMissing: (String) throws -> Void = { _ in }
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let env = resolvedEnvironment(overlaying: command.extraEnvironment)

        if let tool = command.tool {
            try ensureToolAvailable(tool, in: env, onMissing: onToolMissing)
        }

        let (shell, args) = loginShell(for: command.commandLine)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = args
        process.environment = env
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch {
            throw ShellRunnerError.launchFailed(error.localizedDescription)
        }

        var timedOut = false
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                }
            }
        }

        return AsyncThrowingStream { continuation in
            // `Process`/`Pipe`'s FileHandle are not Sendable (Foundation
            // types). Under Swift 6 strict concurrency we hand them to a
            // `nonisolated` helper that owns them for the lifetime of the pump:
            // from spawn until waitUntilExit returns, after which the stream
            // finishes and nothing else touches them. The helper spawns its own
            // detached task internally so this build closure captures nothing
            // non-Sendable.
            Self.startPump(
                pipe: pipe,
                process: process,
                timedOut: timedOut,
                timeout: timeout,
                into: continuation
            )
        }
    }

    /// Spawns the background pump task. `nonisolated` + `nonisolated(unsafe)`
    /// params let the non-Sendable `Process`/`Pipe` cross the isolation
    /// boundary: this is safe because nothing else touches them between spawn
    /// and the pump's `waitUntilExit` (the stream is the sole consumer).
    nonisolated private static func startPump(
        pipe nonisolatedPipe: Pipe,
        process nonisolatedProcess: Process,
        timedOut: Bool,
        timeout: TimeInterval?,
        into continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        let readHandle = nonisolatedPipe.fileHandleForReading
        Task.detached(priority: .userInitiated) {
            var accumulated = Data()
            while true {
                let chunk = readHandle.availableData
                if chunk.isEmpty {
                    // EOF — pipe closed, process is finishing.
                    break
                }
                accumulated.append(chunk)
                continuation.yield(chunk)
            }
            nonisolatedProcess.waitUntilExit()
            if timedOut {
                continuation.finish(throwing: ShellRunnerError.timedOut(seconds: timeout ?? 0))
                return
            }
            if nonisolatedProcess.terminationStatus != 0 {
                let out = String(data: accumulated, encoding: .utf8) ?? ""
                continuation.finish(throwing: ShellRunnerError.launchFailed("Exit \(nonisolatedProcess.terminationStatus): \(out)"))
                return
            }
            continuation.finish()
        }
    }

    // MARK: Environment + shell resolution

    /// The augmented environment: inherited env, overlaid with any extras, with
    /// common tool directories prepended to PATH.
    private static func resolvedEnvironment(overlaying extras: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extras { env[k] = v }
        env["PATH"] = augmentedPATH(base: env["PATH"] ?? "")
        return env
    }

    /// Builds a PATH string with existing tool directories (those that exist on
    /// disk) prepended to `base`, de-duplicated.
    private static func augmentedPATH(base: String) -> String {
        let fm = FileManager.default
        var seen = Set<String>()
        let prepend = toolPathDirs.filter { fm.isExecutableFile(atPath: $0) && seen.insert($0).inserted }
        return (prepend + [base]).joined(separator: ":")
    }

    /// Returns the user's default login shell and the arg vector to run
    /// `commandLine` as a non-interactive login shell. Falls back to `/bin/sh`
    /// (always present on macOS) if the configured shell can't be determined.
    ///
    /// The version-manager bootstrap is prepended to `commandLine` so nvm/fnm/
    /// volta/bun contribute their bin dirs to PATH before the command runs —
    /// `toolPathDirs` can't reach those (version-specific) directories.
    private static func loginShell(for commandLine: String) -> (shell: String, args: [String]) {
        let full = versionManagerBootstrap + "\n" + commandLine
        let shell = defaultShell()
        switch (shell as NSString).lastPathComponent {
        case "zsh", "bash", "fish":
            return (shell, ["-l", "-c", full])
        default:
            // /bin/sh fallback (always available): not a login shell, but PATH
            // augmentation above already covers the common tool locations.
            return ("/bin/sh", ["-c", full])
        }
    }

    /// The user's configured login shell, from the passwd database, falling back
    /// to `$SHELL` and finally `/bin/sh`.
    private static func defaultShell() -> String {
        if let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell,
           let shell = String(cString: s, encoding: .utf8), !shell.isEmpty {
            return shell
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/sh"
    }

    /// Pre-flights `tool` by asking the user's login shell (with the version-
    /// manager bootstrap applied) whether it resolves. Running the check through
    /// the same shell that will run the command means the pre-flight sees the
    /// identical PATH — including nvm/fnm/volta version dirs that only exist
    /// after sourcing, which a plain `which` against the process env would miss.
    /// Calls `onMissing` (which should throw the caller-specific error) if the
    /// tool isn't resolvable.
    private static func ensureToolAvailable(
        _ tool: String,
        in env: [String: String],
        onMissing: (String) throws -> Void
    ) throws {
        let check = versionManagerBootstrap + "\ncommand -v " + shellQuote(tool) + " >/dev/null 2>&1"
        let shell = defaultShell()
        let shellName = (shell as NSString).lastPathComponent
        let args: [String] = shellName == "zsh" || shellName == "bash" || shellName == "fish"
            ? ["-l", "-c", check]
            : ["-c", check]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = args
        process.environment = env
        // If the shell itself fails to launch, let the real command fail naturally.
        do { try process.run() } catch { return }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try onMissing(tool)
            return
        }
    }
}

/// Errors raised by `ShellRunner`, decoupled from any domain-specific error type.
enum ShellRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let s): "Could not launch tool: \(s)"
        case .timedOut(let s): "Timed out after \(Int(s))s — the command didn't finish. The database may be unreachable."
        }
    }
}
