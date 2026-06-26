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

    /// Executes `command`, returning its combined stdout+stderr.
    ///
    /// - Parameter onToolMissing: invoked (synchronously) when the command's tool
    ///   isn't on PATH; the closure should return/throw the caller-specific
    ///   error to raise. This keeps `ShellRunner` decoupled from any particular
    ///   domain's error types.
    @discardableResult
    static func run(
        command: ShellCommand,
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

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch {
            throw ShellRunnerError.launchFailed(error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw ShellRunnerError.launchFailed("Exit \(process.terminationStatus): \(output)")
        }
        return output
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
    private static func loginShell(for commandLine: String) -> (shell: String, args: [String]) {
        let shell = defaultShell()
        switch (shell as NSString).lastPathComponent {
        case "zsh", "bash", "fish":
            return (shell, ["-l", "-c", commandLine])
        default:
            // /bin/sh fallback (always available): not a login shell, but PATH
            // augmentation above already covers the common tool locations.
            return ("/bin/sh", ["-c", commandLine])
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

    /// Pre-flights `tool` via `which`; calls `onMissing` (which should throw the
    /// caller-specific error) if it isn't resolvable on PATH in `env`.
    private static func ensureToolAvailable(
        _ tool: String,
        in env: [String: String],
        onMissing: (String) throws -> Void
    ) throws {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [tool]
        which.environment = env
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = pipe
        // If `which` itself fails to launch, let the real command fail naturally.
        do { try which.run() } catch { return }
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        which.waitUntilExit()
        guard which.terminationStatus == 0 else {
            try onMissing(tool)
            return
        }
    }
}

/// Errors raised by `ShellRunner`, decoupled from any domain-specific error type.
enum ShellRunnerError: Error, LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let s): "Could not launch tool: \(s)"
        }
    }
}
