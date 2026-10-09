import Foundation

/// Display limits from core/src/constants.ts.
let bashCommandDisplayMaxLength = 30
let taskDescriptionDisplayMaxLength = 40

private func truncated(_ s: String, _ max: Int) -> String {
    s.count > max ? String(s.prefix(max)) + "\u{2026}" : s
}

private func baseName(_ value: Any?) -> String {
    guard let path = value as? String else { return "" }
    return (path as NSString).lastPathComponent
}

/// Port of `formatToolStatus` (server/src/providers/hook/claude/claude.ts).
public func formatToolStatus(_ toolName: String, _ input: [String: Any]) -> String {
    switch toolName {
    case "Read": return "Reading \(baseName(input["file_path"]))"
    case "Edit": return "Editing \(baseName(input["file_path"]))"
    case "Write": return "Writing \(baseName(input["file_path"]))"
    case "Bash":
        let cmd = input["command"] as? String ?? ""
        return "Running: \(truncated(cmd, bashCommandDisplayMaxLength))"
    case "Glob": return "Searching files"
    case "Grep": return "Searching code"
    case "WebFetch": return "Fetching web content"
    case "WebSearch": return "Searching the web"
    case "Task", "Agent":
        let desc = input["description"] as? String ?? ""
        return desc.isEmpty ? "Running subtask" : "Subtask: \(truncated(desc, taskDescriptionDisplayMaxLength))"
    case "AskUserQuestion": return "Waiting for your answer"
    case "EnterPlanMode": return "Planning"
    case "NotebookEdit": return "Editing notebook"
    case "TeamCreate":
        let team = input["team_name"] as? String ?? ""
        return team.isEmpty ? "Creating team" : "Creating team: \(team)"
    case "SendMessage":
        let recipient = input["recipient"] as? String ?? ""
        return recipient.isEmpty ? "Sending message" : "-> \(recipient)"
    default: return "Using \(toolName)"
    }
}
