import Foundation

public enum AgentState: Int, Comparable {
    /// Fresh session, nothing has happened yet.
    case idle
    /// Turn finished (Stop).
    case done
    /// Claude went idle waiting on the user (Notification idle_prompt).
    case waiting
    /// Running tools.
    case working
    /// Blocked on a permission prompt.
    case permission

    public static func < (a: AgentState, b: AgentState) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .idle: return "idle"
        case .done: return "done"
        case .waiting: return "waiting for input"
        case .working: return "working"
        case .permission: return "needs permission"
        }
    }

    /// Working and permission sessions scurry; the rest amble.
    public var isBusy: Bool { self == .working || self == .permission }
}

public struct Agent {
    public let id: String
    public var cwd: String?
    public var state: AgentState = .idle
    public var label: String = ""
    public var subagents: Int = 0
    public var lastEventAt: Date
    public var stateSince: Date
    var toolStarts: [Date] = []

    public var project: String {
        guard let cwd, !cwd.isEmpty else { return String(id.prefix(8)) }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? cwd : base
    }

    /// Tool starts in the last `window` seconds.
    public func toolRate(now: Date, window: TimeInterval = 10) -> Int {
        toolStarts.filter { (0...window).contains(now.timeIntervalSince($0)) }.count
    }
}

/// session_id -> Agent. Main-thread only (callers hop to the main queue).
public final class AgentStore {
    public private(set) var agents: [String: Agent] = [:]

    /// Idle, done and waiting sessions with no event for this long are dropped.
    public static let quietExpiry: TimeInterval = 30 * 60
    /// Working and permission sessions get longer, since a tool call can run for a long time.
    public static let busyExpiry: TimeInterval = 60 * 60

    public init() {}

    public func apply(_ hook: NormalizedHook, now: Date = Date()) {
        if case .sessionEnd = hook.event {
            agents.removeValue(forKey: hook.sessionId)
            return
        }

        // Hooks installed after a session started: adopt it on first sight.
        var agent = agents[hook.sessionId] ?? Agent(id: hook.sessionId, cwd: hook.cwd, lastEventAt: now, stateSince: now)
        if let cwd = hook.cwd, !cwd.isEmpty { agent.cwd = cwd }
        agent.lastEventAt = now

        let before = agent.state
        switch hook.event {
        case .sessionStart:
            agent.state = .idle
            agent.label = ""
            agent.subagents = 0
            agent.toolStarts = []
        case let .toolStart(_, label):
            agent.state = .working
            agent.label = label
            agent.toolStarts.append(now)
            agent.toolStarts.removeAll { now.timeIntervalSince($0) > 60 }
        case .toolEnd:
            // Permission is cleared by the tool actually running.
            if agent.state == .permission { agent.state = .working }
        case .permissionRequest:
            agent.state = .permission
        case let .turnEnd(awaitingInput):
            agent.state = awaitingInput ? .waiting : .done
            agent.label = ""
            // A finished turn means its subagents are finished too; this keeps a missed
            // SubagentStop from leaving a pet running forever. (Background subagents that
            // outlive the turn lose their pet early.)
            if !awaitingInput { agent.subagents = 0 }
        case .subagentStart:
            agent.subagents += 1
        case .subagentEnd:
            agent.subagents = max(0, agent.subagents - 1)
        case .sessionEnd:
            break
        }
        if agent.state != before { agent.stateSince = now }
        agents[hook.sessionId] = agent
    }

    /// Drops sessions that have gone quiet. Returns the removed ids.
    @discardableResult
    public func expireStale(now: Date = Date()) -> [String] {
        let stale = agents.values.filter {
            let limit = $0.state.isBusy ? Self.busyExpiry : Self.quietExpiry
            return now.timeIntervalSince($0.lastEventAt) > limit
        }.map(\.id)
        for id in stale { agents.removeValue(forKey: id) }
        return stale
    }

    /// Separator in a subagent pet's id: `<session id>#<n>`.
    public static let subagentMarker: Character = "#"

    /// What the lane draws: every session, plus one extra pet per running subagent.
    /// Subagent pets copy their parent (same species) and always scurry, since a subagent is working.
    public func petEntities() -> [Agent] {
        sorted().flatMap { agent -> [Agent] in
            guard agent.subagents > 0 else { return [agent] }
            let subs = (0..<agent.subagents).map { i -> Agent in
                var sub = agent
                sub = Agent(id: "\(agent.id)\(Self.subagentMarker)\(i)", cwd: agent.cwd,
                            lastEventAt: agent.lastEventAt, stateSince: agent.stateSince)
                sub.state = .working
                sub.toolStarts = agent.toolStarts
                return sub
            }
            return [agent] + subs
        }
    }

    /// Most urgent first, then by project name.
    public func sorted() -> [Agent] {
        agents.values.sorted {
            if $0.state != $1.state { return $0.state > $1.state }
            if $0.project != $1.project { return $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}
