import Foundation

/// Runs a command synchronously (off the main actor) and returns its output.
/// Used for short, fire-and-forget commands like `prisma migrate status`.
enum ProcessRunner {

    struct Result: Sendable {
        let exitCode: Int
        let stdout: String
        let stderr: String
        var isSuccess: Bool { exitCode == 0 }
        var combinedOutput: String { stdout + (stderr.isEmpty ? "" : "\n" + stderr) }
    }

    /// Runs `executable args...` in `directory` with the given environment.
    static func run(
        executable: String,
        arguments: [String],
        directory: String,
        environment: [String: String]? = nil
    ) async -> Result {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: "Launch failed: \(error.localizedDescription)")
        }

        // Off-main synchronous read. Acceptable for the short migrate-status
        // calls this serves; revisit if longer-running commands route here.
        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitCode: Int(process.terminationStatus),
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Runs a shell command string via a **login** zsh in `directory`.
    /// Use this when the command must resolve through the user's PATH
    /// (pnpm/npx/bunx/yarn), which a GUI-launched app doesn't inherit by default.
    ///
    /// Uses a login NON-interactive shell (`-l -c`): this sources `.zprofile`
    /// (and `.zshrc`'s PATH contributions that aren't gated on interactivity)
    /// WITHOUT sourcing the interactive `.zshrc` banner/prompt code — so custom
    /// prompts, "ZK-Scripts loaded!" style banners, and other interactive-only
    /// output never leak into the captured command output.
    ///
    /// Node version managers (nvm, fnm, volta) typically wire themselves up in
    /// `.zshrc`, which a non-interactive shell skips — so we source the common
    /// ones explicitly to make `npx`/`node` resolvable. The sourced snippets are
    /// all no-ops if the tool isn't installed.
    static func run(shellCommand: String, directory: String) async -> Result {
        // Prepend bootstrap lines that add node's bin dir to PATH. Each is
        // guarded so it silently no-ops when the version manager is absent.
        let bootstrap = """
        [ -s \"$HOME/.nvm/nvm.sh\" ] && . \"$HOME/.nvm/nvm.sh\" 2>/dev/null
        command -v fnm >/dev/null 2>&1 && eval \"$(fnm env --shell zsh 2>/dev/null)\"
        [ -s \"$HOME/.volta/bin\" ] && export PATH=\"$HOME/.volta/bin:$PATH\"
        [ -s \"$HOME/.bun/bin\" ] && export PATH=\"$HOME/.bun/bin:$PATH\"
        """
        let full = bootstrap + "\n" + shellCommand
        return await run(
            executable: "/bin/zsh",
            arguments: ["-l", "-c", full],
            directory: directory,
            environment: ["HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()]
        )
    }
}
