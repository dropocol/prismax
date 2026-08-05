import SwiftUI
import SwiftData

/// Root three-column layout: sidebar (projects + history) → project workspace
/// → live output inspector.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel

    @Query(sort: \Project.orderIndex) private var projects: [Project]

    var body: some View {
        @Bindable var appModel = appModel
        NavigationSplitView {
            SidebarView(
                projects: projects,
                onAddProject: { appModel.showingAddProject = true }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            contentColumn
        }
        .sheet(isPresented: $appModel.showingAddProject) {
            AddProjectSheet(prefilledURL: appModel.pendingImportURL) { url, detection, isBackupsOnly in
                appModel.pendingImportURL = nil
                addProject(from: url, detection: detection, isBackupsOnly: isBackupsOnly)
            }
        }
        .onChange(of: projects.count) {
            // Clear the selection if the selected project was deleted.
            if case .project(let id) = appModel.sidebarSelection,
               !projects.contains(where: { $0.id == id }) {
                appModel.sidebarSelection = nil
            }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch appModel.sidebarSelection {
        case .project(let id):
            if let project = projects.first(where: { $0.id == id }) {
                ProjectDetailView(project: project)
            } else {
                emptyState
            }
        case .history:
            HistoryView()
        case .none:
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: 72, height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 0.5)
                    )
                Image("app_icon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .softShadow(radius: 12, y: 6, opacity: 0.10)
            Text("PrismaX")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Select a project from the sidebar, or add one with ⌘N.")
                .font(.rowSecondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color.primary.opacity(0.015))
    }

    private func addProject(from url: URL, detection: PackageManagerDetector.Detection, isBackupsOnly: Bool) {
        let path = url.path
        let name = url.lastPathComponent

        let project = Project(
            name: name,
            path: path,
            packageManager: detection.packageManager,
            prismaDir: detection.prismaDir,
            schemaPath: detection.schemaPath
        )
        project.isBackupsOnly = isBackupsOnly
        // Seed default commands only for full Prisma projects. Backups-only
        // projects intentionally have no commands (the Commands tab is hidden).
        // Their commands list stays empty; if the user later switches the
        // project back to Prisma via the header menu, defaults are seeded then.
        if !isBackupsOnly {
            project.commands = DefaultCommands.makeCommands()
        }

        let dev = EnvProfile(name: "Development", colorHex: "#34C759", orderIndex: 0)
        dev.project = project

        modelContext.insert(project)
        try? modelContext.save()

        appModel.sidebarSelection = .project(project.id)
    }
}

enum SidebarItem: Hashable {
    case project(UUID)
    case history
}
