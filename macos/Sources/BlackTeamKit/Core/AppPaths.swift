import Foundation

/// Where Black Team keeps its files on a Mac.
public enum AppPaths {
    /// The data folder (the Linux app's `black-team-data`). `BLACK_TEAM_DATA`, when it is an
    /// absolute path, replaces it so a clean install can be tried without touching real data.
    public static func dataFolder(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: String = NSHomeDirectory()) -> String {
        if let override = environment["BLACK_TEAM_DATA"], override.hasPrefix("/") {
            var path = override
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return path
        }
        return home + "/Library/Application Support/Black Team"
    }

    /// The folder the app works in until the person picks another. It stays `~/Black Team`
    /// as on Linux: a folder in Documents would make macOS ask for permission at first use.
    public static func defaultWorkspace(home: String = NSHomeDirectory()) -> String {
        home + "/Black Team"
    }
}
