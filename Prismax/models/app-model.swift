import SwiftUI
import SwiftData

/// App-wide UI state shared across views via the environment.
@Observable
final class AppModel {
    var selectedProjectID: UUID?
    var showingAddProject: Bool = false
    var showingSettings: Bool = false
    var pendingImportURL: URL?

    @MainActor
    func handleImportedURL(_ url: URL) {
        // Resolve security-scoped / file reference URLs to a real path.
        didBecomeActive(url)
    }

    private func didBecomeActive(_ url: URL) {
        if url.hasDirectoryPath {
            pendingImportURL = url
            showingAddProject = true
        }
    }
}
