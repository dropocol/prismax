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
    @State private var restoreTarget: BackupResult?
    @State private var scheduleEnabled = false
    @State private var scheduleFrequency: BackupFrequency = .daily
    @State private var backupFormat: BackupFormat = .compressed
    @State private var schemaOnly = false
    @State private var crossEnvTarget: BackupResult?
    @State private var crossEnvDestination: EnvProfile?

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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backupCard
                storageCard
                scheduleCard
                historyCard
            }
            .padding(16)
        }
        .onAppear { refresh() }
        .onChange(of: environment.id) { refresh() }
        .alert("Restore Backup?", isPresented: Binding(
            get: { restoreTarget != nil },
            set: { if !$0 { restoreTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { restoreTarget = nil }
            Button("Restore", role: .destructive) {
                if let target = restoreTarget { performRestore(target) }
                restoreTarget = nil
            }
        } message: {
            if let target = restoreTarget {
                Text("Restoring \(target.fileURL.lastPathComponent) will overwrite the current **\(environment.name)** database. This cannot be undone.")
            }
        }
        .alert("Restore to Another Environment?", isPresented: Binding(
            get: { crossEnvTarget != nil },
            set: { if !$0 { crossEnvTarget = nil; crossEnvDestination = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                crossEnvTarget = nil
                crossEnvDestination = nil
            }
            Button("Restore", role: .destructive) {
                if let target = crossEnvTarget { performCrossEnvRestore(target) }
                crossEnvTarget = nil
                crossEnvDestination = nil
            }
        } message: {
            if let target = crossEnvTarget, let dest = crossEnvDestination {
                Text("Restoring \(target.fileURL.lastPathComponent) into **\(dest.name)** will overwrite that database. This cannot be undone.")
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

            // Scope: a single-line toggle with inline description.
            Toggle(isOn: $schemaOnly) {
                HStack(spacing: 6) {
                    Text("Public schema only")
                        .font(.rowPrimary)
                    InfoHint(text: "Restricts the backup to the public schema and skips Prisma's _prisma_migrations rows. This produces a portable DATA snapshot — safe to restore across environments (e.g. prod → staging) without overwriting the target's migration state. Turn OFF for a full, exact clone of the database (same environment or disaster recovery). Postgres only.")
                    Text("·  skips `_prisma_migrations`")
                        .font(.rowSecondary)
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(!isPostgres)
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
                            onRestore: { restoreTarget = backup },
                            onReveal: { BackupService.reveal(fileURL: backup.fileURL) },
                            onDelete: { delete(backup) },
                            crossDestinations: crossDestinations,
                            onCrossEnvRestore: { dest in
                                crossEnvTarget = backup
                                crossEnvDestination = dest
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

    private func performRestore(_ backup: BackupResult) {
        guard let url = resolvedDatabaseURL else { return }
        isRestoring = true
        statusMessage = nil
        Task {
            do {
                _ = try await BackupService.restore(databaseURL: url, from: backup.fileURL)
                await MainActor.run {
                    isRestoring = false
                    statusMessage = "Restore complete."
                    statusError = false
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    statusMessage = error.localizedDescription
                    statusError = true
                }
            }
        }
    }

    /// Restores `backup` into a different environment's database
    /// (`crossEnvDestination`), leaving the source file in place.
    private func performCrossEnvRestore(_ backup: BackupResult) {
        guard let dest = crossEnvDestination,
              let targetURL = resolvedURL(for: dest) else { return }
        isRestoring = true
        statusMessage = nil
        Task {
            do {
                _ = try await BackupService.restoreCrossEnvironment(from: backup.fileURL, toDatabaseURL: targetURL)
                await MainActor.run {
                    isRestoring = false
                    statusMessage = "Restored into \(dest.name)."
                    statusError = false
                }
            } catch {
                await MainActor.run {
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

private struct BackupRow: View {
    let backup: BackupResult
    let onRestore: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let crossDestinations: [EnvProfile]
    let onCrossEnvRestore: (EnvProfile) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.accent.opacity(0.08))
                    .frame(width: 28, height: 28)
                Image(systemName: "doc.zipper")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.fileURL.lastPathComponent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(backup.createdAt, format: .dateTime.month().day().hour().minute())
                    Text("·").foregroundStyle(.tertiary)
                    Text(backup.sizeBytes.formattedBytes)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !crossDestinations.isEmpty {
                Menu {
                    ForEach(crossDestinations) { dest in
                        Button(dest.name) { onCrossEnvRestore(dest) }
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Restore into another environment")
            }
            Button("Restore", systemImage: "arrow.uturn.backward", action: onRestore)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(action: onReveal) {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .cardStyle(cornerRadius: 8)
    }
}

/// A small info glyph that surfaces a longer explanation via the native macOS
/// hover tooltip. Keeps the layout compact while making option trade-offs
/// discoverable — consistent with the app's existing `.help()` usage.
private struct InfoHint: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .help(text)
    }
}
