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

struct SubagentInfo {
    var firstSeen: Date
    var lastSeen: Date
}

public struct Agent {
    public let id: String
    public var cwd: String?
    public var state: AgentState = .idle
    public var label: String = ""
    /// Where this session's transcript lives, from the hook payloads.
    public var transcriptPath: String?
    /// Raw model id read from the transcript, e.g. "claude-sonnet-5-5".
    public var model: String?
    public var modelName: String? { model.map(ModelName.display) }
    /// Running subagents by `agent_id`. A subagent lives from its first sighting (SubagentStart, or
    /// any of its tool calls if the start was missed) until its own SubagentStop, even past the
    /// parent's turn; it is dropped if it goes silent for `AgentStore.subagentExpiry`.
    var subagentInfo: [String: SubagentInfo] = [:]
    /// Recently stopped subagents, so a late event from one does not bring its pet back.
    var subagentEnded: [String: Date] = [:]
    public var subagents: Int { subagentInfo.count }
    public var lastEventAt: Date
    public var stateSince: Date
    var toolStarts: [Date] = []

    public var project: String {
        guard let cwd, !cwd.isEmpty else { return String(id.prefix(8)) }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? cwd : base
    }

    /// Marks a subagent as alive now, adding it if new, unless it only just stopped.
    mutating func touchSubagent(_ id: String, now: Date) {
        if let ended = subagentEnded[id], now.timeIntervalSince(ended) < AgentStore.subagentEndedGrace { return }
        subagentEnded.removeValue(forKey: id)
        if var info = subagentInfo[id] {
            info.lastSeen = now
            subagentInfo[id] = info
        } else {
            subagentInfo[id] = SubagentInfo(firstSeen: now, lastSeen: now)
        }
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
    /// Backstop for a SubagentStop that never arrives.
    public static let subagentExpiry: TimeInterval = 15 * 60
    /// A stopped subagent's late events are ignored for this long.
    static let subagentEndedGrace: TimeInterval = 5

    public init() {}

    public func apply(_ hook: NormalizedHook, now: Date = Date()) {
        if case .sessionEnd = hook.event {
            agents.removeValue(forKey: hook.sessionId)
            return
        }

        // Hooks installed after a session started: adopt it on first sight.
        var agent = agents[hook.sessionId] ?? Agent(id: hook.sessionId, cwd: hook.cwd, lastEventAt: now, stateSince: now)
        if let cwd = hook.cwd, !cwd.isEmpty { agent.cwd = cwd }
        if let path = hook.transcriptPath, !path.isEmpty { agent.transcriptPath = path }
        agent.lastEventAt = now

        // Events from a subagent say which subagent is alive. They never change the parent's own
        // state: the parent may be idle while its subagents work.
        if let sub = hook.agentId {
            switch hook.event {
            case .subagentEnd:
                agent.subagentInfo.removeValue(forKey: sub)
                agent.subagentEnded[sub] = now
                agents[hook.sessionId] = agent
                return
            case .subagentStart:
                agent.subagentEnded.removeValue(forKey: sub)
                agent.touchSubagent(sub, now: now)
            case .toolStart, .toolEnd:
                agent.touchSubagent(sub, now: now)
                if case .toolStart = hook.event {
                    agent.toolStarts.append(now)
                    agent.toolStarts.removeAll { now.timeIntervalSince($0) > 60 }
                }
                agents[hook.sessionId] = agent
                return
            default:
                agent.touchSubagent(sub, now: now)
            }
        }

        let before = agent.state
        switch hook.event {
        case .sessionStart:
            agent.state = .idle
            agent.label = ""
            agent.subagentInfo = [:]
            agent.subagentEnded = [:]
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
            // Subagents are left alone: background ones keep running after the parent goes idle.
        case .subagentStart:
            // No agent_id (not seen in practice): count it under a made-up id.
            if hook.agentId == nil { agent.touchSubagent("anon-\(now.timeIntervalSince1970)-\(agent.subagentInfo.count)", now: now) }
        case .subagentEnd:
            if hook.agentId == nil, let oldest = agent.subagentInfo.filter({ $0.key.hasPrefix("anon-") }).min(by: { $0.value.firstSeen < $1.value.firstSeen }) {
                agent.subagentInfo.removeValue(forKey: oldest.key)
            }
        case .sessionEnd:
            break
        }
        if agent.state != before { agent.stateSince = now }
        agents[hook.sessionId] = agent
    }

    /// Records the model read from a session's transcript. Returns true if it changed.
    @discardableResult
    public func setModel(_ model: String?, forSession id: String) -> Bool {
        guard var agent = agents[id], let model, agent.model != model else { return false }
        agent.model = model
        agents[id] = agent
        return true
    }

    /// Drops subagents that have run suspiciously long. Returns true if any pet went away.
    @discardableResult
    public func pruneSubagents(now: Date = Date()) -> Bool {
        var changed = false
        for id in Array(agents.keys) {
            guard var agent = agents[id] else { continue }
            let kept = agent.subagentInfo.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.subagentExpiry }
            agent.subagentEnded = agent.subagentEnded.filter { now.timeIntervalSince($0.value) < Self.subagentEndedGrace }
            if kept.count != agent.subagentInfo.count {
                agent.subagentInfo = kept
                agents[id] = agent
                changed = true
            } else {
                agents[id] = agent
            }
        }
        return changed
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
            // Oldest first, so a pet keeps its place in the order as others come and go.
            let ordered = agent.subagentInfo.sorted { ($0.value.firstSeen, $0.key) < ($1.value.firstSeen, $1.key) }
            let subs = ordered.map { (id, _) -> Agent in
                var sub = agent
                sub = Agent(id: "\(agent.id)\(Self.subagentMarker)\(id)", cwd: agent.cwd,
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
