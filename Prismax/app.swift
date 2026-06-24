import SwiftUI
import SwiftData

@main
struct PrismaxApp: App {
    let modelContainer: ModelContainer

    @State private var appModel = AppModel()
    @State private var runService = RunService()
    @State private var terminalManager = TerminalManager()

    init() {
        do {
            modelContainer = try ModelContainer(
                for: Project.self, EnvProfile.self, EnvVariable.self,
                Command.self, Guardrail.self, RunRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(runService)
                .environment(terminalManager)
                .onAppear {
                    // RunService dispatches commands through the terminal
                    // manager, so it needs a reference to it.
                    runService.attach(terminalManager)
                    // Restore persisted backup schedules now that SwiftData is up.
                    BackupScheduler.shared.restoreSchedules(modelContext: modelContainer.mainContext)
                }
                .frame(minWidth: 960, minHeight: 640)
                .tint(Theme.accent)
                .onOpenURL { url in
                    // Allow dragging a folder onto the dock icon.
                    appModel.handleImportedURL(url)
                }
        }
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Project…") { appModel.showingAddProject = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appModel.showingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(appModel)
                .frame(width: 420)
        }
    }
}
