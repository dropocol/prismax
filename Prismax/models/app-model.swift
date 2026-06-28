import SwiftUI
import SwiftData

/// App-wide UI state shared across views via the environment.
@Observable
final class AppModel {
    /// The sidebar item shown in the detail column. Lifted here from
    /// `ContentView` so other views (e.g. the delete confirmation in the
    /// sidebar) can clear it without an extra binding.
    var sidebarSelection: SidebarItem?

    /// A run the user wants History to focus on — set when they click a recent
    /// run in the sidebar (or elsewhere). History reads it, selects + briefly
    /// highlights that row, then clears it. nil means "no focus requested".
    var focusedRunID: UUID?

    var showingAddProject: Bool = false
    var showingSettings: Bool = false
    var pendingImportURL: URL?

    @MainActor
    func handleImportedURL(_ url: URL) {
        // Resolve security-scoped / file reference URLs (e.g. a folder dropped
        // onto the dock icon) to a real path, then hand off to the add sheet.
        guard url.hasDirectoryPath else { return }
        pendingImportURL = url
        showingAddProject = true
    }
}
