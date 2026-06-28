import SwiftUI
import SwiftData

/// Timeline of past command runs. Each row shows what ran, against which
/// environment, and the outcome. The rerun button re-dispatches the command
/// into the project's integrated terminal — which is shown in a right-docked
/// panel here so the user sees live output without leaving History.
///
/// When navigated to with `appModel.focusedRunID` set (e.g. from the sidebar's
/// Recent Activity), the matching row is selected, scrolled into view, and
/// briefly highlighted with an accent flash so it's easy to spot.
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RunService.self) private var runService
    @Environment(AppModel.self) private var appModel
    @Query(sort: \RunRecord.startedAt, order: .reverse) private var records: [RunRecord]
    @Query private var projects: [Project]

    /// The project whose terminal is docked on the right. Set when the user
    /// reruns (or selects) a record; the dock shows that project's live shell.
    @State private var dockedProjectID: UUID?
    @State private var dockedEnvID: UUID?
    @State private var selectedRecordID: UUID?
    /// Row briefly flashed when jumped to from elsewhere (sidebar focus).
    @State private var highlightedRecordID: UUID?
    @AppStorage("historyTerminalWidth") private var dockWidthRaw: Double = 460

    private var dockWidth: CGFloat {
        get { CGFloat(dockWidthRaw) }
        set { dockWidthRaw = Double(newValue) }
    }

    private var widthBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(dockWidthRaw) }, set: { dockWidthRaw = Double($0) })
    }

    /// Resolves the docked project + the environment to run against (the
    /// record's env if known, else the project's first environment).
    private var docked: (project: Project, env: EnvProfile)? {
        guard let pid = dockedProjectID,
              let project = projects.first(where: { $0.id == pid }) else { return nil }
        let envs = project.environments.sorted(by: { $0.orderIndex < $1.orderIndex })
        if let eid = dockedEnvID,
           let env = envs.first(where: { $0.id == eid }) {
            return (project, env)
        }
        if let env = envs.first { return (project, env) }
        return nil
    }

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Runs will appear here once you execute a command.")
                )
            } else {
                HStack(spacing: 0) {
                    historyList
                    if docked != nil {
                        ResizeDivider(orientation: .vertical,
                                      value: widthBinding,
                                      range: 280...900)
                        dock
                    }
                }
            }
        }
        // Consume a focus request from elsewhere (e.g. sidebar Recent Activity):
        // select + briefly highlight the targeted run, then clear the request.
        .onChange(of: appModel.focusedRunID) { _, id in
            guard let id else { return }
            selectedRecordID = id
            flashHighlight(id)
            appModel.focusedRunID = nil
        }
        .onAppear {
            if let id = appModel.focusedRunID {
                selectedRecordID = id
                flashHighlight(id)
                appModel.focusedRunID = nil
            }
        }
    }

    private var historyList: some View {
        List(selection: Binding(
            get: { selectedRecordID },
            set: { selectedRecordID = $0 }
        )) {
            ForEach(records) { record in
                HStack(spacing: 8) {
                    RunRecordRow(record: record, highlighted: highlightedRecordID == record.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        rerun(record)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Rerun")
                }
                .contextMenu {
                    Button("Rerun", systemImage: "arrow.clockwise") { rerun(record) }
                    Button("Open in Project", systemImage: "arrow.up.right.square") {
                        appModel.sidebarSelection = .project(record.projectId)
                    }
                    Button("Copy Output", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.output, forType: .string)
                    }
                    .disabled(record.output.isEmpty)
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        modelContext.delete(record)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// The right-docked terminal bound to the rerun target. Reuses the same
    /// `TerminalPanel` the project workspace uses, so output is identical.
    @ViewBuilder
    private var dock: some View {
        if let (project, env) = docked {
            VStack(spacing: 0) {
                dockHeader(project: project)
                TerminalPanel(project: project, environment: env)
                    .id(project.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: dockWidth)
        }
    }

    private func dockHeader(project: Project) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Text(project.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Button {
                appModel.sidebarSelection = .project(project.id)
            } label: {
                Label("Open in Project", systemImage: "arrow.up.right.square")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this project's workspace")
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    dockedProjectID = nil
                    dockedEnvID = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide terminal")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }

    // MARK: Actions

    private func rerun(_ record: RunRecord) {
        // Dock the record's project so the rerun is visible, then dispatch.
        withAnimation(.snappy(duration: 0.2)) {
            dockedProjectID = record.projectId
            dockedEnvID = record.environmentId
            selectedRecordID = record.id
        }
        runService.rerun(record, modelContext: modelContext)
    }

    /// Flashes the highlight on a row for ~1.6s so a focus jump is easy to spot.
    private func flashHighlight(_ id: UUID) {
        highlightedRecordID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if highlightedRecordID == id { highlightedRecordID = nil }
        }
    }
}
