import SwiftUI
import SwiftData

struct SidebarView: View {
    let projects: [Project]
    @Binding var selection: SidebarItem?
    let onAddProject: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var renamingProject: Project?
    @State private var renameText = ""
    @State private var deletingProject: Project?

    var body: some View {
        List(selection: $selection) {
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
                NavigationLink(value: SidebarItem.history) {
                    HistoryRow()
                }
            } header: {
                sectionHeader("Activity")
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
                    modelContext.delete(project)
                    try? modelContext.save()
                    if case .project(let id) = selection, id == project.id {
                        selection = nil
                    }
                }
                deletingProject = nil
            }
        } message: {
            if let project = deletingProject {
                Text("Remove \"\(project.name)\" from Prismax? This also removes its environments, commands, and run history. Your files on disk are not touched.")
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
            Image(systemName: "square.dashed")
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
                    Text(project.packageManager.label.uppercased())
                        .font(.micro)
                        .tracking(0.3)
                        .foregroundStyle(.tertiary)
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
