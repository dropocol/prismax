import SwiftUI
import SwiftData

struct BackupsTab: View {
    let project: Project
    let environment: EnvProfile

    @Environment(\.modelContext) private var modelContext
    @State private var backups: [BackupResult] = []
    @State private var isBackingUp = false
    @State private var isRestoring = false
    @State private var statusMessage: String?
    @State private var statusError = false
    @State private var scheduleEnabled = false
    @State private var scheduleFrequency: BackupFrequency = .daily
    @State private var backupFormat: BackupFormat = .compressed
    @State private var schemaOnly = false

    /// The restore the user is confirming in the sheet (destination + backup).
    /// Set by either restore-menu choice; the sheet pre-fills mode/parallel
    /// from Settings and lets the user override per-restore.
    @State private var pendingRestore: PendingRestore?
    @AppStorage("restoreMode") private var restoreModeDefaultRaw: String = RestoreMode.clean.rawValue
    @AppStorage("restoreParallel") private var restoreParallelDefault = true

    /// Live progress for an in-flight restore. While non-nil, a right-side
    /// inspector panel docks into the tab showing the streaming restore log.
    @State private var restoreProgress: RestoreProgress?
    @AppStorage("restorePanelWidth") private var panelWidthRaw: Double = 380
    private var panelWidth: CGFloat { CGFloat(panelWidthRaw) }
    private var panelWidthBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(panelWidthRaw) }, set: { panelWidthRaw = Double($0) })
    }

    /// Resolved DATABASE_URL for the current environment, sourced from the
    /// connected `.env` file AND Keychain variables (via `EnvironmentResolver`),
    /// not Keychain alone — so an env-file-only `DATABASE_URL` is recognized.
    @State private var resolvedDatabaseURL: String?

    /// Other environments with a resolvable DATABASE_URL — destinations for
    /// cross-environment restore. Resolved alongside `resolvedDatabaseURL`.
    @State private var crossDestinations: [EnvProfile] = []

    /// The on-disk directory backups for this environment are written to/read
    /// from (after applying per-project override → global default → built-in).
    @State private var backupDirectoryURL: URL = BackupSettings.builtInDefaultRoot

    private var isPostgres: Bool {
        guard let scheme = resolvedDatabaseURL.flatMap({ URL(string: $0)?.scheme }) else { return false }
        return ["postgresql", "postgres"].contains(scheme.lowercased())
    }

    var body: some View {
        HStack(spacing: 0) {
            // The tab's normal scrollable content.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    backupCard
                    storageCard
                    scheduleCard
                    historyCard
                }
                .padding(16)
            }

            // Right-side restore progress inspector. Visible only while a
            // restore is in flight (or just finished, awaiting dismissal).
            if let progress = restoreProgress {
                ResizeDivider(orientation: .vertical,
                              value: panelWidthBinding,
                              range: 280...720)
                RestoreProgressPanel(progress: progress) {
                    withAnimation(.snappy(duration: 0.2)) { restoreProgress = nil }
                }
                .frame(width: panelWidth)
            }
        }
        .onAppear { refresh() }
        .onChange(of: environment.id) { refresh() }
        // Single restore-confirmation sheet for both same-env and cross-env
        // restores. Pre-fills mode/parallel from Settings; the user can change
        // them per-restore. Confirms with the chosen (mode, parallel).
        .sheet(isPresented: Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        )) {
            if let pending = pendingRestore {
                RestoreConfirmationSheet(
                    backupFileName: pending.backup.fileURL.lastPathComponent,
                    destinationName: pending.destinationName,
                    isCrossEnvironment: pending.isCrossEnvironment,
                    mode: RestoreMode(rawValue: restoreModeDefaultRaw) ?? .clean,
                    parallel: restoreParallelDefault,
                    onConfirm: { mode, parallel in
                        let confirmed = pending
                        pendingRestore = nil
                        runRestore(confirmed, mode: mode, parallel: parallel)
                    },
                    onCancel: { pendingRestore = nil }
                )
            }
        }
    }

    // MARK: - Backup card

    /// Primary action card: provider status, format/scope options, and the
    /// backup button — or, when no DATABASE_URL resolves, guidance on where to
    /// add one (variable OR connected .env file).
    private var backupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: icon + title on the left, provider badge on the right.
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.accent.opacity(0.10))
                        .frame(width: 30, height: 30)
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Backup & Restore")
                        .font(.rowPrimary)
                    Text("Snapshot this environment's database to a file.")
                        .font(.rowSecondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = resolvedDatabaseURL {
                    providerBadge(for: url)
                }
            }

            if resolvedDatabaseURL != nil {
                backupOptionsRow
                actionRow
            } else {
                noURLState
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// Backup format and scope options, laid out as tidy labeled rows. The
    /// format picker and schema-only toggle are Postgres-only refinements.
    private var backupOptionsRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Format: label left, segmented picker right.
            HStack(spacing: 12) {
                Text("Format")
                    .font(.rowPrimary)
                    .foregroundStyle(.secondary)
                InfoHint(text: "Choose how the backup is written. Compressed (.dump) is compact and restores via pg_restore; Plain SQL (.sql) is human-readable and restores via psql — handy for inspecting or diffing the dump before restore. Postgres only.")
                Picker("Format", selection: $backupFormat) {
                    ForEach(BackupFormat.allCases) { f in Text(f.label).tag(f) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!isPostgres)
            }

            Divider().padding(.vertical, 10)

            // Scope: toggle + inline note + info, kept as siblings so the info
            // glyph sits OUTSIDE the toggle's tappable label.
            HStack(spacing: 6) {
                Toggle(isOn: $schemaOnly) {
                    Text("Data-only backup")
                        .font(.rowPrimary)
                }
                .disabled(!isPostgres)
                InfoHint(text: "Backs up only the public schema and skips Prisma's _prisma_migrations rows. This produces a portable DATA snapshot — safe to restore across environments (e.g. prod → staging) without overwriting the target's migration state. Turn OFF for a full, exact clone of the database (same environment or disaster recovery). Postgres only.")
                Text("·  skips `_prisma_migrations`")
                    .font(.rowSecondary)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }

    /// The primary backup button (left) with the result status to its right.
    private var actionRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                performBackup()
            } label: {
                HStack(spacing: 6) {
                    if isBackingUp {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text(isBackingUp ? "Backing up…" : "Back up now")
                        .font(.rowPrimary)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBackingUp)

            if let statusMessage {
                statusPill(message: statusMessage, error: statusError)
                // When the run failed, offer a copy button so the (often long,
                // truncated) tool error can be copied for diagnostics.
                if statusError {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(statusMessage, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.primary.opacity(0.06))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy error")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var noURLState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No DATABASE_URL resolved", systemImage: "exclamationmark.triangle.fill")
                .font(.rowPrimary)
                .foregroundStyle(Theme.warning)
            Text("Add `DATABASE_URL` as a variable to **\(environment.name)**, or connect a `.env` file that defines it, in the Environments tab.")
                .font(.rowSecondary)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.warning.opacity(0.08))
        )
    }

    // MARK: - Storage card

    /// Shows where this environment's backups are stored, with the resolved path,
    /// a "Show in Finder" action, and a per-project location override.
    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Storage location")
                    .font(.rowPrimary)
                Spacer()
            }

            // The effective path for THIS environment (override > global > built-in).
            HStack(spacing: 6) {
                Text(backupDirectoryURL.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    BackupService.revealDirectory(backupDirectoryURL)
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Show this environment's backup folder in Finder")
            }

            Divider()

            overrideControl
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// Per-project override toggle/picker. When set, this project's backups go
    /// to the chosen folder instead of the app-wide default.
    private var overrideControl: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Project folder")
                    .font(.rowPrimary)
                if let override = project.backupDirectoryOverride, !override.isEmpty {
                    Text("Using project override")
                        .font(.rowSecondary)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("Using app default")
                        .font(.rowSecondary)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Choose…") { chooseBackupFolder() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if project.backupDirectoryOverride != nil {
                Button("Reset") { clearBackupFolderOverride() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.directoryURL = URL(fileURLWithPath: project.path)
        if panel.runModal() == .OK, let url = panel.url {
            project.backupDirectoryOverride = url.path
            try? modelContext.save()
            refresh()
        }
    }

    private func clearBackupFolderOverride() {
        project.backupDirectoryOverride = nil
        try? modelContext.save()
        refresh()
    }

    // MARK: - Schedule card

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Automatic schedule")
                    .font(.rowPrimary)
                Spacer()
                Toggle("", isOn: $scheduleEnabled)
                    .labelsHidden()
                    .onChange(of: scheduleEnabled) { _, on in
                        if on { BackupScheduler.shared.schedule(project: project, environment: environment, frequency: scheduleFrequency) }
                        else { BackupScheduler.shared.cancel(project: project, environment: environment) }
                    }
            }

            if scheduleEnabled {
                Divider()
                Picker("Frequency", selection: $scheduleFrequency) {
                    ForEach(BackupFrequency.allCases) { freq in Text(freq.label).tag(freq) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: scheduleFrequency) { _, freq in
                    BackupScheduler.shared.schedule(project: project, environment: environment, frequency: freq)
                }
                Text("Runs automatically while PrismaX is open. A background LaunchAgent is planned for a future update.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - History card

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("History")
                    .font(.micro)
                    .tracking(0.5)
                Spacer()
                Text("\(backups.count) backups")
                    .font(.micro)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.tertiary)

            if backups.isEmpty {
                Text("No backups yet.")
                    .font(.rowPrimary)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
            } else {
                VStack(spacing: 6) {
                    ForEach(backups) { backup in
                        BackupRow(
                            backup: backup,
                            currentEnvironmentName: environment.name,
                            onRestore: {
                                pendingRestore = PendingRestore(
                                    backup: backup,
                                    destination: environment,
                                    destinationName: environment.name,
                                    isCrossEnvironment: false
                                )
                            },
                            onReveal: { BackupService.reveal(fileURL: backup.fileURL) },
                            onDelete: { delete(backup) },
                            crossDestinations: crossDestinations,
                            onCrossEnvRestore: { dest in
                                pendingRestore = PendingRestore(
                                    backup: backup,
                                    destination: dest,
                                    destinationName: dest.name,
                                    isCrossEnvironment: true
                                )
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers


    private func providerBadge(for url: String) -> some View {
        guard let parsed = URL(string: url), let scheme = parsed.scheme,
              let provider = BackupService.Provider(urlScheme: scheme) else {
            return AnyView(EmptyView())
        }
        return AnyView(
            HStack(spacing: 4) {
                Circle().fill(Theme.success).frame(width: 6, height: 6)
                Text(provider.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.success.opacity(0.10)))
            .foregroundStyle(Theme.success)
        )
    }

    private func statusPill(message: String, error: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: error ? "xmark.octagon.fill" : "checkmark.circle.fill")
            Text(message).font(.system(size: 11.5))
        }
        .foregroundStyle(error ? Theme.danger : Theme.success)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill((error ? Theme.danger : Theme.success).opacity(0.10)))
    }

    // MARK: - Logic

    private func refresh() {
        backups = BackupService.backups(project: project, environment: environment)
        backupDirectoryURL = BackupSettings.resolvedURL(project: project, environment: environment)
        // Resolve DATABASE_URL via the full env stack (Keychain + .env file),
        // and gather other environments that can serve as cross-restore targets.
        resolvedDatabaseURL = resolvedURL(for: environment)
        crossDestinations = project.environments
            .filter { $0.id != environment.id && resolvedURL(for: $0) != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if let freq = BackupScheduler.shared.frequency(forEnvironment: environment.id) {
            scheduleEnabled = true
            scheduleFrequency = freq
        } else {
            scheduleEnabled = false
        }
    }

    /// Resolves a DATABASE_URL for `env` the same way commands do: Keychain
    /// variables overlaid on the connected `.env` file. Returns nil if neither
    /// defines one.
    @MainActor
    private func resolvedURL(for env: EnvProfile) -> String? {
        EnvironmentResolver.resolve(project: project, environment: env)["DATABASE_URL"]
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private func performBackup() {
        guard let url = resolvedDatabaseURL else { return }
        // Resolve the directory on the main actor (reads SwiftData models),
        // then pass Sendable scalars into the detached Task.
        let dir = BackupSettings.resolvedURL(project: project, environment: environment)
        let envName = environment.name
        isBackingUp = true
        statusMessage = nil
        Task {
            do {
                _ = try await BackupService.backup(
                    databaseURL: url,
                    environmentName: envName,
                    directory: dir,
                    format: backupFormat,
                    schemaOnly: schemaOnly
                )
                await MainActor.run {
                    isBackingUp = false
                    statusMessage = "Backup complete."
                    statusError = false
                    refresh()
                }
            } catch {
                await MainActor.run {
                    isBackingUp = false
                    statusMessage = error.localizedDescription
                    statusError = true
                }
            }
        }
    }

    /// Runs a confirmed restore. Unified path for same-env and cross-env: the
    /// destination (and whether it's cross-env) is captured in `pending`. The
    /// `mode`/`parallel` come from the confirmation sheet (pre-filled from
    /// Settings, overridable per-restore). Streams output to the progress panel.
    private func runRestore(_ pending: PendingRestore, mode: RestoreMode, parallel: Bool) {
        let backup = pending.backup
        let dest = pending.destination
        guard let targetURL = resolvedURL(for: dest) else {
            statusMessage = "\(dest.name) has no resolvable DATABASE_URL."
            statusError = true
            return
        }
        let progress = RestoreProgress(
            backupFileName: backup.fileURL.lastPathComponent,
            destinationName: dest.name
        )
        withAnimation(.snappy(duration: 0.2)) { restoreProgress = progress }
        isRestoring = true
        statusMessage = pending.isCrossEnvironment ? "Restoring into \(dest.name)…" : "Restoring…"
        statusError = false
        Task {
            do {
                let stream = try await BackupService.restoreCrossEnvironmentStreaming(
                    from: backup.fileURL,
                    toDatabaseURL: targetURL,
                    mode: mode,
                    parallel: parallel
                )
                for try await chunk in stream {
                    await MainActor.run { progress.append(chunk) }
                }
                await MainActor.run {
                    progress.succeed()
                    isRestoring = false
                    statusMessage = pending.isCrossEnvironment ? "Restored into \(dest.name)." : "Restore complete."
                    statusError = false
                }
            } catch {
                await MainActor.run {
                    progress.fail(error.localizedDescription)
                    isRestoring = false
                    statusMessage = error.localizedDescription
                    statusError = true
                }
            }
        }
    }

    private func delete(_ backup: BackupResult) {
        try? BackupService.delete(fileURL: backup.fileURL)
        refresh()
    }
}

/// A restore the user is about to confirm in the sheet. Captured at the moment
/// they pick a destination from the Restore menu, then handed to `runRestore`
/// once they confirm (with their chosen mode + parallel setting).
private struct PendingRestore {
    let backup: BackupResult
    let destination: EnvProfile
    let destinationName: String
    let isCrossEnvironment: Bool
}

