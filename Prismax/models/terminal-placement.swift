import Foundation

/// Where the integrated terminal appears within the project workspace.
/// Persisted in @AppStorage("terminalPlacement").
enum TerminalPlacement: String, Identifiable {

    /// Docked at the bottom of the workspace (like VS Code's default).
    case bottom
    /// Docked on the right side of the workspace.
    case right
    /// Hidden — only the tab content shows.
    case hidden

    var id: String { rawValue }

    /// Order shown in the placement picker. Right (side-by-side) comes first so
    /// it's the default-tappable option, matching how the icons are laid out.
    static var allCases: [TerminalPlacement] { [.right, .bottom, .hidden] }

    var label: String {
        switch self {
        case .bottom: "Bottom"
        case .right: "Right"
        case .hidden: "Hidden"
        }
    }

    var symbol: String {
        switch self {
        case .bottom: "square.split.1x2"   // two stacked rows → terminal below
        case .right: "square.split.2x1"    // two side-by-side columns → terminal right
        case .hidden: "rectangle"          // single panel, no terminal
        }
    }
}

/// How command runs map to terminals. Persisted in
/// @AppStorage("terminalMode").
enum TerminalMode: String, CaseIterable, Identifiable {
    /// One persistent terminal per project; every command types into it.
    case persistent
    /// Each command run opens a new terminal tab you can switch between.
    case perCommand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .persistent: "One persistent terminal"
        case .perCommand: "New tab per command"
        }
    }
}

/// How a restore prepares the destination before loading data. Persisted in
/// @AppStorage("restoreMode"). Controls the flags passed to `pg_restore` /
/// the pre-restore SQL, trading speed against safety.
enum RestoreMode: String, CaseIterable, Identifiable {
    /// Drop and recreate every object (`pg_restore --clean --if-exists`).
    /// Safest and fully idempotent — no primary-key conflicts possible — but
    /// slowest because each object is dropped then re-created sequentially.
    case clean
    /// TRUNCATE all tables first, then load fresh data. Faster than `clean`
    /// (no per-object drop/recreate) and produces a clean result, but needs
    /// the destination's table structure to already match the backup.
    case truncate
    /// Load data straight on top of whatever's in the destination — no drops,
    /// no truncates. Fastest, but risks primary-key conflicts if the target
    /// already contains overlapping rows. Best into empty/fresh databases.
    case append

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clean: "Drop & recreate (safe)"
        case .truncate: "Truncate then load"
        case .append: "Append into target (fastest)"
        }
    }

    /// One-line help shown under each option in Settings.
    var help: String {
        switch self {
        case .clean:
            "Drops and recreates every object before loading. Safest, no conflicts, but slowest."
        case .truncate:
            "Empties all tables first, then loads fresh data. Faster; needs the target schema to match."
        case .append:
            "Loads data on top of existing rows. Fastest; can hit conflicts if the target isn't empty."
        }
    }
}
