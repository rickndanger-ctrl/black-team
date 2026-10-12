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
        #if os(Linux)
        // The Linux app: `black-team-data` under XDG_DATA_HOME (when absolute) or ~/.local/share.
        let share = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home + "/.local/share"
        return share + "/black-team-data"
        #else
        return home + "/Library/Application Support/Black Team"
        #endif
    }

    /// The folder the app works in until the person picks another. It stays `~/Black Team`
    /// as on Linux: a folder in Documents would make macOS ask for permission at first use.
    public static func defaultWorkspace(home: String = NSHomeDirectory()) -> String {
        home + "/Black Team"
    }
}
