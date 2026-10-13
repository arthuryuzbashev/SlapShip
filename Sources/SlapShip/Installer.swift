import Foundation

/// Adds or removes the SlapShip hooks in a Claude Code settings.json.
enum Installer {
    static let events = ["PostToolUse", "UserPromptSubmit"]
    static let marker = "SlapShip hook"

    static var hookCommand: String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "\"\(exe)\" hook"
    }

    static func isInstalled(at url: URL = Paths.claudeSettings) -> Bool {
        guard let settings = load(url), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains(where: isOurs)
        }
    }

    static func install(at url: URL = Paths.claudeSettings) throws {
        var settings = load(url) ?? [:]
        backup(url)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            var group: [String: Any] = ["hooks": [["type": "command", "command": hookCommand, "timeout": 5]]]
            if event == "PostToolUse" { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try save(settings, to: url)
    }

    static func uninstall(at url: URL = Paths.claudeSettings) throws {
        guard var settings = load(url), var hooks = settings["hooks"] as? [String: Any] else { return }
        backup(url)
        for event in events {
            let groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try save(settings, to: url)
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        ((group["hooks"] as? [[String: Any]]) ?? []).contains {
            ($0["command"] as? String)?.contains(marker) == true
        }
    }

    private static func load(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func save(_ settings: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// Keeps the user's original file next to it, once.
    private static func backup(_ url: URL) {
        let copy = url.appendingPathExtension("slapship-backup")
        guard FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: copy.path) else { return }
        try? FileManager.default.copyItem(at: url, to: copy)
    }
}
