import Foundation

/// Creates the temp `ZDOTDIR` zsh is pointed at on spawn so it sources our
/// `.zshenv` at startup — the mechanism that installs the exit-code reporter
/// without typing anything into the interactive shell.
///
/// Why a file rather than typing the hook: zsh's line editor echoes anything
/// typed into it (a one-line `source <file>`, a multi-line function body, an
/// appended sentinel — all leak as visible text). A startup file is *sourced*
/// by zsh as part of normal init, never echoed, so it stays invisible.
///
/// The bootstrap `.zshenv`:
///   1. Restores the user's real `ZDOTDIR` so their `.zprofile`/`.zshrc`/
///      `.zlogin` load from the normal location (preserving things like the
///      ZK-Scripts banner).
///   2. Sources the user's own `.zshenv` (zsh skipped it because we redirected
///      `ZDOTDIR` to our dir).
///   3. Registers a `precmd_functions` hook that prints each command's exit
///      code as a hidden OSC 9 sequence (`\e]9;PRISMAX_EXIT:<code>\x07`),
///      which xterm.js consumes without rendering.
enum ShellBootstrap {
    /// The env var carrying the user's original `ZDOTDIR` (or empty if they had
    /// none, in which case zsh defaults to `$HOME`). Set by `TerminalProcess`
    /// before spawn; read by the bootstrap `.zshenv`.
    static let originalZDotDirEnvKey = "PRISMAX_ORIG_ZDOTDIR"

    /// Path to the temp bootstrap directory. Created lazily, once per app
    /// launch, then reused by every spawned shell.
    static let zdotdirPath: String = makeZDotDir()

    private static func makeZDotDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismax-zdotdir-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? zshenvSource.write(to: dir.appendingPathComponent(".zshenv"),
                               atomically: true, encoding: .utf8)
        return dir.path
    }

    /// The `.zshenv` body. Pure POSIX sh so it runs before zsh's own options
    /// are initialized. The `printf` OSC sequence is what `TerminalProcess`
    /// scans the PTY stream for to learn a tracked command's exit code.
    private static let zshenvSource = #"""
# PrismaX exit-code reporter bootstrap.
# Restore the user's real ZDOTDIR so their own zprofile/zshrc/zlogin (and
# anything they print from there, like the ZK-Scripts banner) load normally.
__px_zd="${PRISMAX_ORIG_ZDOTDIR:-$HOME}"
if [ -n "$PRISMAX_ORIG_ZDOTDIR" ]; then
  ZDOTDIR="$PRISMAX_ORIG_ZDOTDIR"
else
  unset ZDOTDIR
fi
# Source the user's real .zshenv (zsh already sourced ours; this runs theirs).
[ -f "$__px_zd/.zshenv" ] && source "$__px_zd/.zshenv"
# Report each command's exit code as a hidden OSC 9 sequence right before the
# next prompt. xterm.js consumes OSC 9 (never rendered), so this is invisible.
__prismax_report_exit() {
  printf '\033]9;PRISMAX_EXIT:%s\007' "$?"
}
precmd_functions=(__prismax_report_exit $precmd_functions)
unset __px_zd
"""#
}
