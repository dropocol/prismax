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
        case .bottom: "square.split.2x1"   // two stacked rows → terminal below
        case .right: "square.split.1x2"    // two side-by-side columns → terminal right
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
