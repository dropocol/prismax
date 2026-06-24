import Foundation

/// Builds the environment dictionary for a spawned process: inherits the base
/// environment, overlays a referenced `.env` file (if any), then overlays
/// Keychain values (which take precedence). The single source of truth for env
/// resolution — used by the terminal manager and SchemaService.
enum EnvironmentResolver {

    /// Resolves the full `[String: String]` environment for running a command
    /// against `env` (the project is needed only to locate a referenced `.env`
    /// file and resolve the project root path).
    @MainActor
    static func resolve(project: Project, environment env: EnvProfile) -> [String: String] {
        var combined = ProcessInfo.processInfo.environment

        // 1. Optional .env file referenced by the environment.
        if let envFilePath = env.envFilePath, !envFilePath.isEmpty {
            let full = (project.path as NSString).appendingPathComponent(envFilePath)
            if let data = FileManager.default.contents(atPath: full),
               let text = String(data: data, encoding: .utf8) {
                for pair in EnvFileImporter.parse(text) {
                    combined[pair.key] = pair.value
                }
            }
        }

        // 2. Keychain variables (take precedence over the .env file).
        for variable in env.variables {
            if let value = try? KeychainService.get(account: variable.keychainAccount) {
                combined[variable.key] = value
            }
        }
        return combined
    }
}
