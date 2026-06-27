import SwiftUI
import SwiftData

struct ProjectDetailView: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(RunService.self) private var runService
    @Environment(TerminalManager.self) private var terminalManager

    @State private var selectedTab: ProjectTab = .commands
    @State private var selectedEnvironmentID: UUID?
    @State private var pendingRun: PendingRun?
    // Stored as Double (UserDefaults/AppStorage don't support CGFloat); bound
    // to the resize dividers as CGFloat so the terminal size persists across
    // launches instead of resetting to the defaults each time.
    @AppStorage("terminalHeight") private var terminalHeightRaw: Double = 240
    @AppStorage("terminalWidth") private var terminalWidthRaw: Double = 460

    private var terminalHeight: CGFloat {
        get { CGFloat(terminalHeightRaw) }
        set { terminalHeightRaw = Double(newValue) }
    }

    private var terminalWidth: CGFloat {
        get { CGFloat(terminalWidthRaw) }
        set { terminalWidthRaw = Double(newValue) }
    }

    /// CGFloat bindings backed by the Double @AppStorage values, for the resize
    /// dividers (which take `Binding<CGFloat>`).
    private var heightBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(terminalHeightRaw) }, set: { terminalHeightRaw = Double($0) })
    }

    private var widthBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(terminalWidthRaw) }, set: { terminalWidthRaw = Double($0) })
    }
    @AppStorage("terminalPlacement") private var placementRaw: String = TerminalPlacement.bottom.rawValue

    private var placement: TerminalPlacement {
        TerminalPlacement(rawValue: placementRaw) ?? .bottom
    }

    private var sortedEnvironments: [EnvProfile] {
        project.environments.sorted(by: { $0.orderIndex < $1.orderIndex })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            workspaceBody
        }
        .onAppear { ensureSelection() }
        .alert("Run on \(pendingRun?.environmentName ?? "")?", isPresented: Binding(
            get: { pendingRun != nil },
            set: { if !$0 { pendingRun = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingRun = nil }
            Button("Run", role: .none) {
                if let run = pendingRun { execute(command: run.command, environment: run.environment) }
                pendingRun = nil
            }
        } message: {
            if let run = pendingRun {
                Text("You're about to run `prisma \(run.command.prismaArgs)` against **\(run.environmentName)**. This command is marked as requiring confirmation on this environment.")
            }
        }
    }

    @ViewBuilder
    private var workspaceBody: some View {
        if let env = selectedEnvironment {
            // The terminal lives in a single stable subtree keyed by project id
            // so its WKWebView/Coordinator (and xterm.js scrollback) survive
            // placement changes. We vary only how the terminal is sized/arranged
            // — never the container type — so SwiftUI keeps the same identity.
            terminalWorkspace(for: env)
        } else {
            ContentUnavailableView(
                "No Environment",
                systemImage: "circle.dashed",
                description: Text("Add an environment to start running commands.")
            )
        }
    }

    /// Renders the tab content + terminal in a layout chosen by `placement`.
    /// The terminal subtree carries `.id(project.id)` so toggling placement
    /// reuses the same `TerminalView` instead of recreating it (which would
    /// reset scrollback). In `.hidden`, the terminal is collapsed to zero size
    /// rather than removed, keeping its shell + scrollback alive offscreen.
    @ViewBuilder
    private func terminalWorkspace(for env: EnvProfile) -> some View {
        switch placement {
        case .bottom:
            VStack(spacing: 0) {
                tabContent(for: env)
                    .id(project.id)
                ResizeDivider(orientation: .horizontal,
                              value: heightBinding,
                              range: 120...600)
                terminalPanel(for: env)
                    .frame(maxWidth: .infinity)
                    .frame(height: terminalHeight)
            }
        case .right:
            HStack(spacing: 0) {
                tabContent(for: env)
                    .id(project.id)
                    .frame(maxWidth: .infinity)
                ResizeDivider(orientation: .vertical,
                              value: widthBinding,
                              range: 280...2000)
                terminalPanel(for: env)
                    .frame(width: terminalWidth, alignment: .leading)
            }
        case .hidden:
            VStack(spacing: 0) {
                tabContent(for: env)
                    .id(project.id)
                // Keep the terminal in the tree (collapsed) so its live shell
                // and scrollback persist while hidden.
                terminalPanel(for: env)
                    .frame(maxWidth: 0, maxHeight: 0)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The terminal panel, given a stable identity per project so it survives
    /// placement switches without being torn down.
    @ViewBuilder
    private func terminalPanel(for env: EnvProfile) -> some View {
        TerminalPanel(project: project, environment: env)
            .id(project.id)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Theme.accent.opacity(0.10))
                        .frame(width: 38, height: 38)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 0.5)
                        )
                    Image(systemName: "shippingbox")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.appTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9.5))
                        Text(project.path)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.tertiary)
                }
                Spacer()

                if let env = selectedEnvironment {
                    Menu {
                        Button("Add Environment…", systemImage: "plus") {
                            NotificationCenter.default.post(name: .addEnvironment, object: project.id)
                        }
                        Divider()
                        ForEach(sortedEnvironments) { e in
                            Button {
                                selectedEnvironmentID = e.id
                            } label: {
                                HStack {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(Color(hex: e.colorHex))
                                    Text(e.name)
                                }
                            }
                        }
                    } label: {
                        EnvironmentChip(environment: env)
                    }
                    .menuStyle(.borderlessButton)
                }
            }

            // Tab bar is the last row of the header; its own bottom hairline
            // doubles as the header/content divider, so a selected tab's
            // underline sits directly on that divider with no gap.
            HStack(spacing: 12) {
                TabBar(selection: $selectedTab)
                Spacer(minLength: 0)
                placementPicker
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func tabContent(for env: EnvProfile) -> some View {
        switch selectedTab {
        case .commands:
            CommandsTab(project: project, environment: env) { command in
                attemptRun(command: command, environment: env)
            }
        case .environments:
            EnvironmentsTab(project: project, environment: env)
        case .backups:
            BackupsTab(project: project, environment: env)
        case .schema:
            SchemaTab(project: project, environment: env)
        }
    }

    /// A compact segmented control to choose where the terminal lives.
    private var placementPicker: some View {
        HStack(spacing: 2) {
            ForEach(TerminalPlacement.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        placementRaw = option.rawValue
                    }
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(placement == option ? Theme.accent : .secondary)
                        .frame(width: 24, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(placement == option ? Theme.accent.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Terminal: \(option.label)")
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }

    /// The environment to run commands against. Falls back to the first one if
    /// the stored selection doesn't resolve — this handles the freshly-added
    /// project case where the SwiftData relationship may not have resolved in
    /// the first render pass (the body would otherwise show "No Environment").
    private var selectedEnvironment: EnvProfile? {
        if let env = sortedEnvironments.first(where: { $0.id == selectedEnvironmentID }) {
            return env
        }
        return sortedEnvironments.first
    }

    private func ensureSelection() {
        // If the stored selection is missing or no longer valid, snap to the
        // first environment so the workspace renders immediately.
        if !sortedEnvironments.contains(where: { $0.id == selectedEnvironmentID }) {
            selectedEnvironmentID = sortedEnvironments.first?.id
        }
    }

    // MARK: Run flow

    private func attemptRun(command: Command, environment env: EnvProfile) {
        let level = guardrailLevel(command: command, environment: env)
        switch level {
        case .allowed:
            execute(command: command, environment: env)
        case .confirm:
            pendingRun = PendingRun(command: command, environment: env, environmentName: env.name)
        case .blocked:
            break
        }
    }

    private func execute(command: Command, environment env: EnvProfile) {
        // RunService dispatches the resolved invocation into the integrated
        // terminal (npx prisma / pnpm dlx prisma / etc., respecting the
        // package manager and --schema setting) and records a RunRecord so the
        // run shows up in History. The real shell resolves the executable via
        // the user's PATH; env vars for the active environment are exported.
        runService.run(command: command, environment: env, project: project, modelContext: modelContext)
    }

    private func guardrailLevel(command: Command, environment env: EnvProfile) -> GuardrailLevel {
        command.guardrails.first(where: { $0.environment?.id == env.id })?.level ?? .allowed
    }
}

enum ProjectTab: String, CaseIterable, Identifiable {
    case commands, environments, backups, schema
    var id: String { rawValue }

    var label: String {
        switch self {
        case .commands: "Commands"
        case .environments: "Environments"
        case .backups: "Backups"
        case .schema: "Schema"
        }
    }

    var symbol: String {
        switch self {
        case .commands: "terminal"
        case .environments: "circle.hexagongrid"
        case .backups: "externaldrive"
        case .schema: "doc.text.magnifyingglass"
        }
    }
}

private struct PendingRun {
    let command: Command
    let environment: EnvProfile
    let environmentName: String
}

extension Notification.Name {
    static let addEnvironment = Notification.Name("prismax.addEnvironment")
}
