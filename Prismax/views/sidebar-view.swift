import SwiftUI
import SwiftData

struct SidebarView: View {
    let projects: [Project]
    let onAddProject: () -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(TerminalManager.self) private var terminalManager
    @State private var renamingProject: Project?
    @State private var renameText = ""
    @State private var deletingProject: Project?

    /// Most recent runs across all projects, newest first. Sliced to a short
    /// window for the sidebar's quick-glance feed.
    @Query(sort: \RunRecord.startedAt, order: .reverse) private var allRecords: [RunRecord]
    private var recentRecords: [RunRecord] { Array(allRecords.prefix(6)) }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { appModel.sidebarSelection },
            set: { appModel.sidebarSelection = $0 }
        )
    }

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                ForEach(projects) { project in
                    NavigationLink(value: SidebarItem.project(project.id)) {
                        ProjectRow(project: project)
                    }
                    .contextMenu {
                        Button("Reveal in Finder", systemImage: "folder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
                        }
                        Button("Rename…", systemImage: "pencil") {
                            renameText = project.name
                            renamingProject = project
                        }
                        Divider()
                        Button("Remove Project", systemImage: "trash", role: .destructive) {
                            deletingProject = project
                        }
                    }
                }
            } header: {
                sectionHeader("Projects")
            }

            Section {
                if recentRecords.isEmpty {
                    NavigationLink(value: SidebarItem.history) {
                        HistoryRow()
                    }
                } else {
                    ForEach(recentRecords) { record in
                        Button {
                            appModel.focusedRunID = record.id
                            appModel.sidebarSelection = .history
                        } label: {
                            RecentActivityRow(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                    NavigationLink(value: SidebarItem.history) {
                        HistoryRow()
                    }
                }
            } header: {
                sectionHeader(recentRecords.isEmpty ? "Activity" : "Recent Activity")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button {
                onAddProject()
            } label: {
                Label("Add Project", systemImage: "plus")
                    .font(.rowPrimary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .background(.bar)
        }
        // Rename dialog
        .alert("Rename Project", isPresented: Binding(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } }
        )) {
            TextField("Project name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingProject = nil }
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { renamingProject?.name = trimmed }
                try? modelContext.save()
                renamingProject = nil
            }
        }
        // Delete confirmation
        .alert("Remove Project?", isPresented: Binding(
            get: { deletingProject != nil },
            set: { if !$0 { deletingProject = nil } }
        )) {
            Button("Cancel", role: .cancel) { deletingProject = nil }
            Button("Remove", role: .destructive) {
                if let project = deletingProject {
                    // Tear down live state for this project before its models
                    // go away, so its terminal shells and backup schedules
                    // aren't left running orphaned.
                    terminalManager.kill(for: project.id)
                    BackupScheduler.shared.cancel(project: project.id)
                    modelContext.delete(project)
                    try? modelContext.save()
                    if case .project(let id) = appModel.sidebarSelection, id == project.id {
                        appModel.sidebarSelection = nil
                    }
                }
                deletingProject = nil
            }
        } message: {
            if let project = deletingProject {
                Text("Remove \"\(project.name)\" from PrismaX? This also removes its environments, commands, and run history. Your files on disk are not touched.")
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.micro)
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }
}

private struct ProjectRow: View {
    let project: Project

    private var envDots: some View {
        HStack(spacing: 3) {
            ForEach(project.environments.sorted(by: { $0.orderIndex < $1.orderIndex })) { env in
                Circle()
                    .fill(Color(hex: env.colorHex))
                    .frame(width: 6, height: 6)
                    .help(env.name)
            }
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: project.isBackupsOnly ? "internaldrive" : "square.dashed")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.rowPrimary)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    envDots
                    if !project.environments.isEmpty {
                        Text("·").foregroundStyle(.tertiary).font(.micro)
                    }
                    // Backups-only projects show a BACKUPS tag instead of the
                    // (meaningless) package manager label.
                    if project.isBackupsOnly {
                        Text("BACKUPS")
                            .font(.micro)
                            .tracking(0.3)
                            .foregroundStyle(Theme.accent)
                    } else {
                        Text(project.packageManager.label.uppercased())
                            .font(.micro)
                            .tracking(0.3)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

private struct HistoryRow: View {
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text("History")
                .font(.rowPrimary)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

/// A compact sidebar row for a recent run: status dot, command name, and the
/// project it ran against. Clicking navigates to the full History view.
private struct RecentActivityRow: View {
    let record: RunRecord

    private var dotColor: Color {
        switch record.status {
        case .running, .dispatched: Theme.running
        case .success: Theme.success
        case .failed: Theme.danger
        case .canceled: Theme.warning
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.commandName)
                    .font(.rowPrimary)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(record.projectName)
                    .font(.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}
