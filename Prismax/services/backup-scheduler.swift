import Foundation
import SwiftUI
import SwiftData

/// How often an automatic backup should run (while the app is open).
enum BackupFrequency: String, CaseIterable, Identifiable, Codable {
    case hourly, daily, weekly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .hourly: 3600
        case .daily: 86_400
        case .weekly: 604_800
        }
    }
}

/// Schedules recurring backups per (project, environment) using `Timer`.
///
/// `frequencies` is the single source of truth for which schedules exist and at
/// what cadence — it drives both the live `Timer`s and the persisted registry,
/// so the UI toggle stays in sync with reality across app restarts. On launch
/// `restoreSchedules(modelContext:)` recreates a `Timer` for every persisted
/// entry. Backups run only while PrismaX is open; a background LaunchAgent is
/// planned for a future update.
@MainActor
final class BackupScheduler {
    static let shared = BackupScheduler()

    private struct Key: Hashable {
        let projectID: UUID
        let envID: UUID
    }

    /// project+env → frequency. Mirrors the active `Timer`s so persistence and
    /// the UI can read cadence without inspecting Timer internals.
    private var frequencies: [Key: BackupFrequency] = [:]
    private var timers: [Key: Timer] = [:]
    /// Captured on restore so timers can re-resolve models from IDs at fire
    /// time (avoiding capturing non-Sendable SwiftData models in the Timer's
    /// @Sendable closure under Swift 6).
    private var modelContext: ModelContext?

    private static let registryKey = "prismax.backupSchedules"

    // MARK: Schedule

    func schedule(project: Project, environment: EnvProfile, frequency: BackupFrequency) {
        let key = Key(projectID: project.id, envID: environment.id)
        timers[key]?.invalidate()

        let timer = makeTimer(for: key, frequency: frequency)
        timers[key] = timer
        frequencies[key] = frequency
        persistRegistry()
    }

    func cancel(project: Project, environment: EnvProfile) {
        cancel(key: Key(projectID: project.id, envID: environment.id))
    }

    /// Cancels all schedules for an environment (used on environment delete).
    func cancel(environment envID: UUID) {
        for key in frequencies.keys.filter({ $0.envID == envID }) {
            cancel(key: key)
        }
    }

    /// Cancels all schedules for a project (used on project delete).
    func cancel(project projectID: UUID) {
        for key in frequencies.keys.filter({ $0.projectID == projectID }) {
            cancel(key: key)
        }
    }

    func cancelAll() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        frequencies.removeAll()
        persistRegistry()
    }

    private func cancel(key: Key) {
        timers[key]?.invalidate()
        timers.removeValue(forKey: key)
        frequencies.removeValue(forKey: key)
        persistRegistry()
    }

    // MARK: Read

    /// The persisted frequency for an environment, or nil if unscheduled. Used
    /// by the Backups tab to render the toggle accurately.
    func frequency(forEnvironment envID: UUID) -> BackupFrequency? {
        for (key, frequency) in frequencies where key.envID == envID {
            return frequency
        }
        return nil
    }

    /// Recreates `Timer`s for every persisted schedule from the model context.
    /// Call once on launch, after SwiftData is ready. Entries whose project or
    /// environment no longer exist are dropped from the registry.
    func restoreSchedules(modelContext: ModelContext) {
        self.modelContext = modelContext
        let entries = registry()
        frequencies.removeAll()
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()

        for entry in entries {
            guard let project = fetchProject(id: entry.projectID, in: modelContext),
                  let env = project.environments.first(where: { $0.id == entry.envID }) else {
                continue
            }
            _ = project; _ = env  // existence check only
            let key = Key(projectID: entry.projectID, envID: entry.envID)
            timers[key] = makeTimer(for: key, frequency: entry.frequency)
            frequencies[key] = entry.frequency
        }
        // Drop any entries we couldn't resolve.
        persistRegistry()
    }

    // MARK: - Private

    /// Builds a timer for `key` that re-resolves the models from IDs at fire
    /// time. Only Sendable values (UUIDs, the @MainActor `self`) are captured.
    private func makeTimer(for key: Key, frequency: BackupFrequency) -> Timer {
        Timer.scheduledTimer(withTimeInterval: frequency.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fireBackup(for: key)
            }
        }
    }

    private func fireBackup(for key: Key) {
        guard let modelContext,
              let project = fetchProject(id: key.projectID, in: modelContext),
              let env = project.environments.first(where: { $0.id == key.envID }) else {
            return
        }
        runBackup(project: project, environment: env)
    }

    private func runBackup(project: Project, environment: EnvProfile) {
        guard let url = environment.variables
            .first(where: { $0.key.uppercased() == "DATABASE_URL" })
            .flatMap({ try? KeychainService.get(account: $0.keychainAccount) }) else {
            return
        }
        Task {
            _ = try? await BackupService.backup(
                databaseURL: url,
                project: project.id,
                environment: environment.id,
                environmentName: environment.name
            )
        }
    }

    // MARK: Registry (UserDefaults-backed for persistence across restarts)

    private struct Entry: Codable {
        let projectID: UUID
        let envID: UUID
        let frequency: BackupFrequency
    }

    private func registry() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: Self.registryKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    private func persistRegistry() {
        let entries = frequencies.map { Entry(projectID: $0.key.projectID, envID: $0.key.envID, frequency: $0.value) }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.registryKey)
        }
    }

    private func fetchProject(id: UUID, in context: ModelContext) -> Project? {
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}
