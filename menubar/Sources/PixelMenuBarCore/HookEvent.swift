import Foundation

/// Normalized hook event. Mirrors the `AgentEvent` union that `normalizeHookEvent`
/// (server/src/providers/hook/claude/claude.ts) produces, trimmed to what a menu bar needs.
public enum AgentEvent: Equatable {
    case toolStart(name: String, label: String)
    case toolEnd
    case turnEnd(awaitingInput: Bool)
    case permissionRequest
    case sessionStart
    case sessionEnd
    case subagentStart
    case subagentEnd
}

public struct NormalizedHook: Equatable {
    public let sessionId: String
    public let cwd: String?
    public let transcriptPath: String?
    public let event: AgentEvent

    public init(sessionId: String, cwd: String?, transcriptPath: String? = nil, event: AgentEvent) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.event = event
    }
}

/// Port of `normalizeHookEvent`. Returns nil for events the menu bar ignores
/// (UserPromptSubmit, TaskCreated, TeammateIdle, TaskCompleted, unknown names,
/// and Notification types other than permission_prompt / idle_prompt).
public func normalizeHookEvent(_ raw: [String: Any]) -> NormalizedHook? {
    guard let name = raw["hook_event_name"] as? String,
          let sessionId = raw["session_id"] as? String, !sessionId.isEmpty
    else { return nil }
    let cwd = raw["cwd"] as? String
    let transcriptPath = raw["transcript_path"] as? String

    func make(_ event: AgentEvent) -> NormalizedHook {
        NormalizedHook(sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath, event: event)
    }

    switch name {
    case "PreToolUse":
        let toolName = raw["tool_name"] as? String ?? ""
        let input = raw["tool_input"] as? [String: Any] ?? [:]
        return make(.toolStart(name: toolName, label: formatToolStatus(toolName, input)))
    case "PostToolUse", "PostToolUseFailure":
        return make(.toolEnd)
    case "Stop":
        return make(.turnEnd(awaitingInput: false))
    case "SubagentStart":
        return make(.subagentStart)
    case "SubagentStop":
        return make(.subagentEnd)
    case "PermissionRequest":
        return make(.permissionRequest)
    case "Notification":
        switch raw["notification_type"] as? String ?? "" {
        case "permission_prompt": return make(.permissionRequest)
        case "idle_prompt": return make(.turnEnd(awaitingInput: true))
        default: return nil
        }
    case "SessionStart":
        return make(.sessionStart)
    case "SessionEnd":
        return make(.sessionEnd)
    default:
        return nil
    }
}
