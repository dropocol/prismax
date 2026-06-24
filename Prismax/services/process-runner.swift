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

    /// Runs a shell command string via an interactive login zsh in `directory`.
    /// Use this when the command must resolve through the user's PATH
    /// (pnpm/npx/bunx/yarn), which a GUI-launched app doesn't inherit by default.
    /// Uses -lic so BOTH .zprofile AND .zshrc are sourced (nvm, fnm, volta,
    /// pnpm's installer, bun, and deno add themselves to PATH in .zshrc).
    static func run(shellCommand: String, directory: String) async -> Result {
        await run(
            executable: "/bin/zsh",
            arguments: ["-lic", shellCommand],
            directory: directory,
            environment: ["HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()]
        )
    }
}
