import Foundation

// forkpty() lives in <util.h> but isn't bridged into Swift's Darwin module.
// We declare it directly via @_silgen_name so we can spawn a pseudo-terminal.
@_silgen_name("forkpty")
func c_forkpty(
    _ amaster: UnsafeMutablePointer<Int32>,
    _ name: UnsafeMutablePointer<CChar>?,
    _ termp: OpaquePointer?,
    _ winp: OpaquePointer?
) -> pid_t


/// Spawns an interactive shell inside a pseudo-terminal (PTY) and streams its
/// raw output. This is the bridge between the embedded terminal UI (xterm.js)
/// and a real shell process — it's what makes programs believe they're talking
/// to a terminal, so colors, cursor movement, and interactive prompts all work.
///
/// Architecture:
///   forkpty()  →  child execs /bin/zsh -il  (working dir = project path)
///               parent gets a master fd to read/write
///   A background read loop pumps PTY bytes → an AsyncStream for the UI.
///   The UI sends keystrokes back via send(_:).
@MainActor
@Observable
final class TerminalProcess {
    private(set) var masterFD: Int32 = -1
    private(set) var childPID: pid_t = -1
    private(set) var isRunning = false

    private var readTask: Task<Void, Never>?

    // MARK: Spawn

    /// Spawns a login+interactive zsh in `workingDirectory`, with the given
    /// environment preloaded (Keychain vars + parsed .env file).
    func spawn(
        workingDirectory: String,
        environment: [String: String]
    ) throws {
        // Build the full environment: inherit a sane base, then overlay caller vars.
        var env = ProcessInfo.processInfo.environment
        // Ensure HOME is set (GUI apps have it, but be safe).
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        for (key, value) in environment { env[key] = value }
        // Convert to the char** format execve wants.
        let envPtrs: [UnsafeMutablePointer<CChar>?] = env.map { pair in
            strdup("\(pair.key)=\(pair.value)")
        } + [nil]

        // Resolve the shell and its args.
        let shell = env["SHELL"] ?? "/bin/zsh"
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(shell),
            strdup("-il"),  // interactive + login → sources .zprofile AND .zshrc
            nil
        ]

        // Duplicate the C strings we need to pass by pointer.
        let dirDup = strdup(workingDirectory)

        var master: Int32 = -1
        // Darwin's forkpty() works like fork(2): it returns -1 on error, 0 to
        // the child, and the child's PID to the parent. The master PTY fd is
        // written to the first out-parameter (*amaster). The child already has
        // the slave end wired up as stdin/stdout/stderr.
        let pid = c_forkpty(&master, nil, nil, nil)
        if pid < 0 {
            // Cleanup on failure.
            dirDup?.deallocate()
            for p in argv + envPtrs { p?.deallocate() }
            throw TerminalError.forkFailed(String(cString: strerror(errno)))
        }

        if pid == 0 {
            // ── Child process ──
            chdir(dirDup)
            setenv("TERM", "xterm-256color", 1)
            execve(shell, argv, envPtrs)
            // If execve returns, it failed.
            _exit(127)
        }

        // ── Parent process ──
        dirDup?.deallocate()
        for p in argv { p?.deallocate() }
        for p in envPtrs { p?.deallocate() }

        masterFD = master
        childPID = pid
        isRunning = true

        startReading()
    }

    // MARK: Read loop

    /// Emits raw bytes read from the PTY. The terminal view consumes this and
    /// writes it into xterm.js.
    func outputStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            // Stored so we can finish the stream on stop/exit.
            self.readContinuation = continuation
        }
    }

    private var readContinuation: AsyncStream<Data>.Continuation?

    private func startReading() {
        let fd = masterFD
        readTask = Task.detached(priority: .userInitiated) {
            var buf = [UInt8](repeating: 0, count: 8192)
            while !Task.isCancelled {
                let n = read(fd, &buf, buf.count)
                if n > 0 {
                    let data = Data(buf[0..<n])
                    await MainActor.run {
                        self.readContinuation?.yield(data)
                    }
                } else {
                    // EOF or error — the shell exited.
                    break
                }
            }
            await MainActor.run {
                self.handleExit()
            }
        }
    }

    // MARK: Write

    /// Sends bytes (keystrokes) to the shell's stdin.
    func send(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { rawBuf in
            if let base = rawBuf.baseAddress {
                _ = write(masterFD, base, data.count)
            }
        }
    }

    /// Convenience: send a UTF-8 string.
    func send(_ text: String) {
        send(Data(text.utf8))
    }

    // MARK: Lifecycle

    /// Kills the shell process (SIGTERM then SIGKILL on stubborn processes).
    func terminate() {
        guard childPID > 0 else { return }
        kill(childPID, SIGTERM)
        // Give it a moment, then force-kill.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [childPID] in
            kill(childPID, SIGKILL)
        }
    }

    private func handleExit() {
        isRunning = false
        readContinuation?.finish()
        readContinuation = nil
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        childPID = -1
    }
}

enum TerminalError: Error, LocalizedError {
    case forkFailed(String)

    var errorDescription: String? {
        switch self {
        case .forkFailed(let detail): "Could not start terminal: \(detail)"
        }
    }
}
