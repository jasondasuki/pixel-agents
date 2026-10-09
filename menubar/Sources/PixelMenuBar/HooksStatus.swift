import Foundation

/// Read-only look at ~/.claude/settings.json: which hook events call the pixel-agents script.
/// This app never writes that file; `npx pixel-agents` (or the VS Code extension) installs the hooks.
enum HooksStatus {
    /// Events the installer registers (server/src/providers/hook/claude/constants.ts).
    static let expectedEvents = [
        "SessionStart", "SessionEnd", "Stop", "PermissionRequest", "Notification",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "SubagentStart", "SubagentStop", "TeammateIdle", "TaskCompleted",
    ]
    static let marker = "/.pixel-agents/hooks/claude-hook.js"

    static func installedEventCount(settingsURL: URL = defaultSettingsURL) -> Int? {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return nil }
        return expectedEvents.filter { event in
            guard let value = hooks[event],
                  let blob = try? JSONSerialization.data(withJSONObject: value),
                  let text = String(data: blob, encoding: .utf8) else { return false }
            return text.lowercased().contains(marker)
        }.count
    }

    static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static func summary() -> String {
        guard let count = installedEventCount() else { return "Hooks: can't read ~/.claude/settings.json" }
        if count == 0 { return "Hooks: not installed (run npx pixel-agents once)" }
        return "Hooks: \(count) of \(expectedEvents.count) events installed"
    }
}
