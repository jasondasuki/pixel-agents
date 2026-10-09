import Foundation
import Testing
@testable import PixelMenuBarCore

// MARK: normalizeHookEvent

private func hook(_ name: String, extra: [String: Any] = [:]) -> [String: Any] {
    var raw: [String: Any] = ["hook_event_name": name, "session_id": "s1", "cwd": "/work/api"]
    raw.merge(extra) { $1 }
    return raw
}

@Suite struct NormalizeTests {
    @Test func mapsLifecycleEvents() {
        #expect(normalizeHookEvent(hook("SessionStart"))?.event == .sessionStart)
        #expect(normalizeHookEvent(hook("SessionEnd"))?.event == .sessionEnd)
        #expect(normalizeHookEvent(hook("Stop"))?.event == .turnEnd(awaitingInput: false))
        #expect(normalizeHookEvent(hook("PermissionRequest"))?.event == .permissionRequest)
        #expect(normalizeHookEvent(hook("PostToolUse"))?.event == .toolEnd)
        #expect(normalizeHookEvent(hook("PostToolUseFailure"))?.event == .toolEnd)
        #expect(normalizeHookEvent(hook("SubagentStart"))?.event == .subagentStart)
        #expect(normalizeHookEvent(hook("SubagentStop"))?.event == .subagentEnd)
    }

    @Test func notificationTypes() {
        #expect(normalizeHookEvent(hook("Notification", extra: ["notification_type": "permission_prompt"]))?.event == .permissionRequest)
        #expect(normalizeHookEvent(hook("Notification", extra: ["notification_type": "idle_prompt"]))?.event == .turnEnd(awaitingInput: true))
        #expect(normalizeHookEvent(hook("Notification", extra: ["notification_type": "auth_success"])) == nil)
        #expect(normalizeHookEvent(hook("Notification")) == nil)
    }

    @Test func preToolUseCarriesLabelAndCwd() {
        let n = normalizeHookEvent(hook("PreToolUse", extra: ["tool_name": "Read", "tool_input": ["file_path": "/x/foo.ts"]]))
        #expect(n?.event == .toolStart(name: "Read", label: "Reading foo.ts"))
        #expect(n?.cwd == "/work/api")
        #expect(n?.sessionId == "s1")
    }

    @Test func ignoresWhatItShould() {
        for name in ["UserPromptSubmit", "TaskCreated", "TeammateIdle", "TaskCompleted", "Mystery"] {
            #expect(normalizeHookEvent(hook(name)) == nil)
        }
        #expect(normalizeHookEvent(["hook_event_name": "Stop"]) == nil)
        #expect(normalizeHookEvent(["session_id": "s1"]) == nil)
        #expect(normalizeHookEvent(["hook_event_name": "Stop", "session_id": ""]) == nil)
    }
}

// MARK: formatToolStatus parity with claude.ts

@Suite struct ToolStatusTests {
    @Test func matchesTypeScript() {
        #expect(formatToolStatus("Edit", ["file_path": "/a/b/main.tf"]) == "Editing main.tf")
        #expect(formatToolStatus("Write", ["file_path": "/a/b/c.md"]) == "Writing c.md")
        #expect(formatToolStatus("Read", [:]) == "Reading ")
        #expect(formatToolStatus("Glob", [:]) == "Searching files")
        #expect(formatToolStatus("Grep", [:]) == "Searching code")
        #expect(formatToolStatus("WebFetch", [:]) == "Fetching web content")
        #expect(formatToolStatus("WebSearch", [:]) == "Searching the web")
        #expect(formatToolStatus("AskUserQuestion", [:]) == "Waiting for your answer")
        #expect(formatToolStatus("EnterPlanMode", [:]) == "Planning")
        #expect(formatToolStatus("NotebookEdit", [:]) == "Editing notebook")
        #expect(formatToolStatus("TeamCreate", ["team_name": "red"]) == "Creating team: red")
        #expect(formatToolStatus("TeamCreate", [:]) == "Creating team")
        #expect(formatToolStatus("SendMessage", ["recipient": "bob"]) == "-> bob")
        #expect(formatToolStatus("SendMessage", [:]) == "Sending message")
        #expect(formatToolStatus("mcp__x__y", [:]) == "Using mcp__x__y")
    }

    @Test func truncation() {
        #expect(formatToolStatus("Bash", ["command": "ls"]) == "Running: ls")
        let long = String(repeating: "a", count: 31)
        #expect(formatToolStatus("Bash", ["command": long]) == "Running: " + String(repeating: "a", count: 30) + "\u{2026}")
        let exact = String(repeating: "a", count: 30)
        #expect(formatToolStatus("Bash", ["command": exact]) == "Running: " + exact)
        #expect(formatToolStatus("Task", [:]) == "Running subtask")
        #expect(formatToolStatus("Agent", ["description": "x"]) == "Subtask: x")
        let desc = String(repeating: "d", count: 41)
        #expect(formatToolStatus("Task", ["description": desc]) == "Subtask: " + String(repeating: "d", count: 40) + "\u{2026}")
    }
}

// MARK: HTTP parsing and auth

private func request(method: String = "POST", path: String = HookRequestHandler.path, headers: [String: String] = [:], body: String = "{}") -> Data {
    var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n"
    for (k, v) in headers { head += "\(k): \(v)\r\n" }
    return Data((head + "\r\n" + body).utf8)
}

@Suite struct HTTPTests {
    @Test func parsesCompleteRequest() {
        guard case let .request(r) = HTTPRequestParser.parse(request(headers: ["Authorization": "Bearer t"], body: "{\"a\":1}")) else {
            Issue.record("expected request"); return
        }
        #expect(r.method == "POST")
        #expect(r.path == "/api/hooks/claude")
        #expect(r.headers["authorization"] == "Bearer t")
        #expect(String(data: r.body, encoding: .utf8) == "{\"a\":1}")
    }

    @Test func waitsForMoreData() {
        let full = request(body: "{\"hello\":\"world\"}")
        #expect(HTTPRequestParser.parse(full.dropLast(3)) == .needMore)
        #expect(HTTPRequestParser.parse(Data("POST /x HTTP/1.1\r\nHost: a".utf8)) == .needMore)
    }

    @Test func rejectsOversizeBody() {
        let head = "POST /api/hooks/claude HTTP/1.1\r\nContent-Length: \(maxHookBodySize + 1)\r\n\r\n"
        #expect(HTTPRequestParser.parse(Data(head.utf8)) == .reject(413))
    }

    @Test func rejectsMalformed() {
        #expect(HTTPRequestParser.parse(Data("garbage\r\n\r\n".utf8)) == .reject(400))
        #expect(HTTPRequestParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8)) == .reject(400))
        #expect(HTTPRequestParser.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .reject(501))
        #expect(HTTPRequestParser.parse(Data(repeating: 65, count: maxHeaderSize + 10)) == .reject(431))
    }

    @Test func handlerAuthAndRouting() {
        let handler = HookRequestHandler(token: "secret")
        func run(_ data: Data) -> Int {
            guard case let .request(r) = HTTPRequestParser.parse(data) else { return -1 }
            return handler.handle(r).status
        }
        let stop = "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\"}"
        #expect(run(request(headers: ["Authorization": "Bearer secret"], body: stop)) == 204)
        #expect(run(request(headers: ["Authorization": "Bearer wrong"], body: stop)) == 401)
        #expect(run(request(headers: ["Authorization": "Bearer secre"], body: stop)) == 401)
        #expect(run(request(body: stop)) == 401)
        #expect(run(request(method: "GET", headers: ["Authorization": "Bearer secret"])) == 405)
        #expect(run(request(path: "/other", headers: ["Authorization": "Bearer secret"])) == 404)
        #expect(run(request(headers: ["Authorization": "Bearer secret"], body: "not json")) == 400)
    }

    @Test func handlerAcknowledgesIgnoredEvents() {
        let handler = HookRequestHandler(token: "secret")
        guard case let .request(r) = HTTPRequestParser.parse(request(
            headers: ["Authorization": "Bearer secret"],
            body: "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\"}"
        )) else { Issue.record("expected request"); return }
        let response = handler.handle(r)
        #expect(response.status == 204)
        #expect(response.hook == nil)
    }
}

// MARK: AgentStore

private func apply(_ store: AgentStore, _ event: AgentEvent, session: String = "s1", cwd: String? = "/work/api", at t: TimeInterval = 0) {
    store.apply(NormalizedHook(sessionId: session, cwd: cwd, event: event), now: Date(timeIntervalSince1970: t))
}

@Suite struct AgentStoreTests {
    @Test func lifecycle() {
        let store = AgentStore()
        apply(store, .sessionStart)
        #expect(store.agents["s1"]?.state == .idle)
        apply(store, .toolStart(name: "Edit", label: "Editing a.ts"))
        #expect(store.agents["s1"]?.state == .working)
        #expect(store.agents["s1"]?.label == "Editing a.ts")
        apply(store, .permissionRequest)
        #expect(store.agents["s1"]?.state == .permission)
        apply(store, .toolEnd)
        #expect(store.agents["s1"]?.state == .working)
        apply(store, .turnEnd(awaitingInput: false))
        #expect(store.agents["s1"]?.state == .done)
        #expect(store.agents["s1"]?.label == "")
        apply(store, .turnEnd(awaitingInput: true))
        #expect(store.agents["s1"]?.state == .waiting)
        apply(store, .sessionEnd)
        #expect(store.agents.isEmpty)
    }

    @Test func adoptsSessionsFirstSeenMidFlight() {
        let store = AgentStore()
        apply(store, .toolStart(name: "Bash", label: "Running: ls"), session: "late", cwd: "/work/web")
        #expect(store.agents["late"]?.state == .working)
        #expect(store.agents["late"]?.project == "web")
    }

    @Test func toolEndDoesNotReviveDoneSession() {
        let store = AgentStore()
        apply(store, .turnEnd(awaitingInput: false))
        apply(store, .toolEnd)
        #expect(store.agents["s1"]?.state == .done)
    }

    @Test func subagentCounterNeverGoesNegative() {
        let store = AgentStore()
        apply(store, .subagentEnd)
        #expect(store.agents["s1"]?.subagents == 0)
        apply(store, .subagentStart)
        apply(store, .subagentStart)
        apply(store, .subagentEnd)
        #expect(store.agents["s1"]?.subagents == 1)
    }

    @Test func expiry() {
        let store = AgentStore()
        apply(store, .turnEnd(awaitingInput: false), session: "quiet", at: 0)
        apply(store, .toolStart(name: "Bash", label: "x"), session: "busy", at: 0)
        #expect(store.expireStale(now: Date(timeIntervalSince1970: AgentStore.quietExpiry - 1)).isEmpty)
        #expect(store.expireStale(now: Date(timeIntervalSince1970: AgentStore.quietExpiry + 1)) == ["quiet"])
        #expect(store.expireStale(now: Date(timeIntervalSince1970: AgentStore.busyExpiry + 1)) == ["busy"])
        #expect(store.agents.isEmpty)
    }

    @Test func sortsMostUrgentFirst() {
        let store = AgentStore()
        apply(store, .turnEnd(awaitingInput: false), session: "a", cwd: "/z/alpha")
        apply(store, .permissionRequest, session: "b", cwd: "/z/beta")
        apply(store, .toolStart(name: "Read", label: "r"), session: "c", cwd: "/z/gamma")
        #expect(store.sorted().map(\.id) == ["b", "c", "a"])
    }

    @Test func subagentsGetTheirOwnPets() {
        let store = AgentStore()
        apply(store, .turnEnd(awaitingInput: true), session: "p", cwd: "/z/p")
        apply(store, .subagentStart, session: "p")
        apply(store, .subagentStart, session: "p")
        var pets = store.petEntities()
        #expect(pets.map(\.id) == ["p", "p#0", "p#1"])
        #expect(pets[1].state == .working && pets[2].state == .working)
        #expect(pets[0].state == .waiting)
        #expect(pets[1].project == pets[0].project)

        apply(store, .subagentEnd, session: "p")
        #expect(store.petEntities().map(\.id) == ["p", "p#0"])
        // A subagent outlives the parent's turn: it keeps its pet until its own SubagentStop.
        apply(store, .turnEnd(awaitingInput: false), session: "p")
        pets = store.petEntities()
        #expect(pets.map(\.id) == ["p", "p#0"])
        #expect(pets[0].state == .done && pets[1].state == .working)
        apply(store, .turnEnd(awaitingInput: true), session: "p")
        #expect(store.petEntities().count == 2)
        apply(store, .subagentEnd, session: "p")
        #expect(store.petEntities().map(\.id) == ["p"])

        // A stop that never arrives is cleaned up by the backstop.
        apply(store, .subagentStart, session: "p", at: 100)
        #expect(!store.pruneSubagents(now: Date(timeIntervalSince1970: 100 + AgentStore.subagentExpiry - 1)))
        #expect(store.pruneSubagents(now: Date(timeIntervalSince1970: 100 + AgentStore.subagentExpiry + 1)))
        #expect(store.petEntities().map(\.id) == ["p"])

        // Sessions without subagents are untouched; no limit on how many.
        for _ in 0..<40 { apply(store, .subagentStart, session: "q") }
        #expect(store.petEntities().filter { $0.id.hasPrefix("q") }.count == 41)
    }

    @Test func toolRateCountsRecentStartsOnly() {
        let store = AgentStore()
        for t in [0.0, 1, 2, 20] { apply(store, .toolStart(name: "Read", label: "r"), at: t) }
        #expect(store.agents["s1"]?.toolRate(now: Date(timeIntervalSince1970: 21)) == 1)
        #expect(store.agents["s1"]?.toolRate(now: Date(timeIntervalSince1970: 5)) == 3)
    }
}

// MARK: Wanderer

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite struct WandererTests {
    @Test func staysInRangeAndKeepsMoving() {
        var rng = SeededRNG(state: 1)
        var w = Wanderer(x: 10, pause: 0.1)
        let range = 0.0...40.0
        var walkedSeconds = 0.0
        for _ in 0..<(60 * 60) {   // 60s at 60fps
            w.step(dt: 1.0 / 60, busy: false, toolRate: 0, range: range, using: &rng)
            #expect(range.contains(w.x))
            if w.walking { walkedSeconds += 1.0 / 60 }
        }
        #expect(walkedSeconds > 2)
    }

    @Test func busyCoversMoreGroundThanCalm() {
        func distance(busy: Bool) -> Double {
            var rng = SeededRNG(state: 7)
            var w = Wanderer(x: 0, pause: 0)
            var total = 0.0, last = w.x
            for _ in 0..<(120 * 30) {
                w.step(dt: 1.0 / 30, busy: busy, toolRate: 5, range: 0...200, using: &rng)
                total += abs(w.x - last); last = w.x
            }
            return total
        }
        #expect(distance(busy: true) > distance(busy: false) * 1.5)
    }

    @Test func clampsWhenLaneShrinks() {
        var rng = SeededRNG(state: 3)
        var w = Wanderer(x: 150, pause: 5)
        w.step(dt: 0.1, busy: false, toolRate: 0, range: 0...20, using: &rng)
        #expect(w.x <= 20)
    }

    @Test func degenerateRangeDoesNotSpin() {
        var rng = SeededRNG(state: 3)
        var w = Wanderer(x: 0, pause: 0)
        for _ in 0..<100 { w.step(dt: 0.1, busy: false, toolRate: 0, range: 0...0, using: &rng) }
        #expect(w.x == 0)
        #expect(!w.walking)
    }

    @Test func framesStayInStrip() {
        var rng = SeededRNG(state: 5)
        var w = Wanderer(x: 0, pause: 0)
        for _ in 0..<500 {
            w.step(dt: 0.05, busy: true, toolRate: 0, range: 0...100, using: &rng)
            #expect((0...2).contains(w.frame))
        }
    }

    @Test func easesInAndOutInsteadOfSnapping() {
        var rng = SeededRNG(state: 11)
        var w = Wanderer(x: 0, pause: 0)
        let range = 0.0...100.0
        var maxStep = 0.0, prevSpeed = 0.0, maxAccel = 0.0, sawWalk = false
        var last = w.x
        let dt = 1.0 / 30
        for _ in 0..<(30 * 120) {
            w.step(dt: dt, busy: false, toolRate: 0, range: range, using: &rng)
            maxStep = max(maxStep, abs(w.x - last)); last = w.x
            if w.walking { sawWalk = true; maxAccel = max(maxAccel, abs(w.speed - prevSpeed) / dt) }
            prevSpeed = w.speed
            #expect(w.speed <= WanderTuning.calmSpeed * WanderTuning.speedJitter.upperBound + 0.001)
        }
        #expect(sawWalk)
        // Per-tick movement never exceeds top speed, and speed changes at the tuned rates (no jumps).
        #expect(maxStep <= WanderTuning.calmSpeed * WanderTuning.speedJitter.upperBound * dt + 0.001)
        #expect(maxAccel <= WanderTuning.deceleration + 1)
    }

    @Test func coversMostOfTheLane() {
        var rng = SeededRNG(state: 21)
        var w = Wanderer(x: 50, pause: 0)
        let range = 0.0...100.0
        var lo = w.x, hi = w.x
        for _ in 0..<(10 * 60 * 60) {   // an hour of idling
            w.step(dt: 0.1, busy: false, toolRate: 0, range: range, using: &rng)
            lo = min(lo, w.x); hi = max(hi, w.x)
        }
        #expect(lo < 10)
        #expect(hi > 90)
    }

    /// Pauses (seconds standing still between walks) and the share of time spent walking.
    private func restAndWalk(busy: Bool, minutes: Double, seed: UInt64) -> (pauses: [Double], walkShare: Double) {
        var rng = SeededRNG(state: seed)
        var w = Wanderer(x: 50, pause: 5)
        var pauses: [Double] = [], current = 0.0, walked = 0.0, wasWalking = false
        let dt = 0.1, steps = Int(minutes * 60 / dt)
        for _ in 0..<steps {
            w.step(dt: dt, busy: busy, toolRate: 0, range: 0...100, using: &rng)
            if w.walking {
                if !wasWalking, current > 0 { pauses.append(current) }
                current = 0; walked += dt
            } else {
                current += dt
            }
            wasWalking = w.walking
        }
        return (pauses, walked / (Double(steps) * dt))
    }

    @Test func idlePetsLoafAround() {
        let idle = restAndWalk(busy: false, minutes: 30, seed: 4)
        // Rests are long (the first one is short by construction), and walking is a small share of the time.
        #expect(idle.pauses.dropFirst().allSatisfy { $0 >= WanderTuning.calmPause.lowerBound - 0.2 })
        #expect(idle.walkShare < 0.1)
        let busy = restAndWalk(busy: true, minutes: 30, seed: 4)
        #expect(busy.walkShare > idle.walkShare * 3)
    }

    @Test func idlePetsDoNotChainWalks() {
        var rng = SeededRNG(state: 8)
        var w = Wanderer(x: 0, pause: 0)
        var walks = 0, wasWalking = false
        for _ in 0..<(10 * 60 * 10) {   // 10 minutes
            w.step(dt: 0.1, busy: false, toolRate: 0, range: 0...100, using: &rng)
            if w.walking, !wasWalking { walks += 1 }
            wasWalking = w.walking
        }
        // One walk, then at least 25s of rest each time: at most ~25 walks in 10 minutes, usually far fewer.
        #expect(walks >= 1 && walks <= 25)
    }

    @Test func settlesWhenBusyEnds() {
        var rng = SeededRNG(state: 2)
        var w = Wanderer(x: 0, pause: 0)
        // Busy for a while: short pauses between walks.
        for _ in 0..<(30 * 10) { w.step(dt: 0.1, busy: true, toolRate: 0, range: 0...100, using: &rng) }
        // Work stops. Let any walk in progress finish, then the pet must rest for a long time.
        var restedSince = 0.0, longestRest = 0.0
        for _ in 0..<(120 * 10) {
            w.step(dt: 0.1, busy: false, toolRate: 0, range: 0...100, using: &rng)
            if w.walking { restedSince = 0 } else { restedSince += 0.1; longestRest = max(longestRest, restedSince) }
        }
        #expect(longestRest >= WanderTuning.calmPause.lowerBound - 0.2)
    }

    @Test func walkFramesSpeedUpWithGroundSpeed() {
        func framesChanged(busy: Bool) -> Int {
            var rng = SeededRNG(state: 9)
            var w = Wanderer(x: 0, pause: 0)
            var changes = 0, last = w.frame
            for _ in 0..<(30 * 30) {
                w.step(dt: 1.0 / 30, busy: busy, toolRate: 0, range: 0...300, using: &rng)
                if w.walking, w.frame != last { changes += 1 }
                last = w.frame
            }
            return changes
        }
        #expect(framesChanged(busy: true) > framesChanged(busy: false))
    }

    @Test func laneSettings() {
        #expect(LaneSetting(stored: nil) == .fixed(320))
        #expect(LaneSetting(stored: 0) == .auto)
        #expect(LaneSetting(stored: 480) == .fixed(480))
        for preset in LaneSetting.presets { #expect(LaneSetting(stored: preset.stored) == preset) }

        // Fixed: same width for 1 or 40 sessions, sleeping pet when there are none.
        #expect(laneWidth(agentCount: 1, setting: .fixed(480)) == 480)
        #expect(laneWidth(agentCount: 40, setting: .fixed(480)) == 480)
        #expect(laneWidth(agentCount: 0, setting: .fixed(480)) == 32)
        // The screen limit wins, for both modes.
        #expect(laneWidth(agentCount: 1, setting: .fixed(640), screenLimit: 500) == 500)
        #expect(laneWidth(agentCount: 9, setting: .auto, screenLimit: 200) == 200)
        #expect(laneWidth(agentCount: 2, setting: .auto) == 150)
    }

    @Test func laneWidthGrowsThenCaps() {
        #expect(growingLaneWidth(agentCount: 0) == 32)
        #expect(growingLaneWidth(agentCount: 1) == 120)
        #expect(growingLaneWidth(agentCount: 2) == 150)
        #expect(growingLaneWidth(agentCount: 500) == 320)
    }
}

// MARK: Model

@Suite struct ModelTests {
    @Test func displayNames() {
        #expect(ModelName.display("claude-sonnet-5-5") == "Sonnet 5.5")
        #expect(ModelName.display("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelName.display("claude-fable-5-1") == "Fable 5.1")
        #expect(ModelName.display("claude-haiku-5-5") == "Haiku 5.5")
        #expect(ModelName.display("claude-opus-4-1-20250805") == "Opus 4.1")
        #expect(ModelName.display("claude-sonnet-4-20250514") == "Sonnet 4")
        #expect(ModelName.display("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ModelName.display("claude-opus-5-5[1m]") == "Opus 5.5 (1M)")
        #expect(ModelName.display("us.anthropic.claude-sonnet-4-5-20250929-v1:0") == "Sonnet 4.5")
        #expect(ModelName.display("gpt-4o") == "Gpt")
        #expect(ModelName.display("1234") == "1234")
    }

    @Test func newestModelInTranscriptWins() {
        let text = """
        {"type":"user","message":{"content":"hi"}}
        {"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}
        {"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[]}}
        {"type":"assistant","message":{"model":"<synthetic>","content":[]}}
        """
        #expect(TranscriptModel.latest(inText: text) == "claude-sonnet-5-5")
        #expect(TranscriptModel.latest(inText: "{\"type\":\"user\"}") == nil)
    }

    @Test func readsOnlyTheTailOfBigFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tr-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let old = "{\"message\":{\"model\":\"claude-opus-5-5\"}}\n"
        let filler = String(repeating: "{\"type\":\"user\",\"x\":\"" + String(repeating: "a", count: 900) + "\"}\n", count: 600)
        let new = "{\"message\":{\"model\":\"claude-sonnet-5-5\"}}\n"
        try (old + filler + new).write(to: url, atomically: true, encoding: .utf8)
        #expect(TranscriptModel.latest(inFileAt: url.path) == "claude-sonnet-5-5")
        #expect(TranscriptModel.latest(inFileAt: "/nonexistent/file.jsonl") == nil)
    }

    @Test func storeKeepsModelPerSession() {
        let store = AgentStore()
        store.apply(NormalizedHook(sessionId: "m", cwd: "/z/m", transcriptPath: "/t/m.jsonl", event: .sessionStart), now: Date(timeIntervalSince1970: 0))
        #expect(store.agents["m"]?.transcriptPath == "/t/m.jsonl")
        #expect(store.agents["m"]?.modelName == nil)
        #expect(store.setModel("claude-sonnet-5-5", forSession: "m"))
        #expect(!store.setModel("claude-sonnet-5-5", forSession: "m"))
        #expect(store.agents["m"]?.modelName == "Sonnet 5.5")
        #expect(!store.setModel("claude-opus-5-5", forSession: "gone"))
        // A later event without a transcript path keeps what is known.
        store.apply(NormalizedHook(sessionId: "m", cwd: nil, event: .toolEnd), now: Date(timeIntervalSince1970: 1))
        #expect(store.agents["m"]?.transcriptPath == "/t/m.jsonl")
    }
}

// MARK: Registry

@Suite struct RegistryTests {
    private func tempRegistry() -> Registry {
        Registry(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(UUID().uuidString)"))
    }

    @Test func writesHookCompatibleRecord() throws {
        let reg = tempRegistry()
        defer { try? FileManager.default.removeItem(at: reg.directory) }
        let entry = RegistryEntry(port: 4321, pid: 99999, token: "tok", startedAt: 1_700_000_000_000)
        try reg.write(entry)

        let url = reg.fileURL(pid: 99999)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        // Exactly the fields isServerConfig() checks.
        #expect(json["port"] as? Int == 4321)
        #expect(json["pid"] as? Int == 99999)
        #expect(json["token"] as? String == "tok")
        #expect(json["startedAt"] as? Int == 1_700_000_000_000)
        #expect(json["servesSpa"] as? Bool == false)
        #expect(json["protocol"] as? Int == 1)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        reg.remove(pid: 99999)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cleanStaleRemovesDeadAndReportsLive() throws {
        let reg = tempRegistry()
        defer { try? FileManager.default.removeItem(at: reg.directory) }
        try reg.write(RegistryEntry(port: 1000, pid: 111, token: "a", startedAt: 1))
        try reg.write(RegistryEntry(port: 2000, pid: 222, token: "b", startedAt: 1))
        let live = reg.cleanStale(isAlive: { $0 == 222 })
        #expect(live?.pid == 222)
        #expect(!FileManager.default.fileExists(atPath: reg.fileURL(pid: 111).path))
        #expect(FileManager.default.fileExists(atPath: reg.fileURL(pid: 222).path))
    }

    @Test func leavesOtherServersFilesAlone() throws {
        let reg = tempRegistry()
        defer { try? FileManager.default.removeItem(at: reg.directory) }
        try FileManager.default.createDirectory(at: reg.directory, withIntermediateDirectories: true)
        let other = reg.directory.appendingPathComponent("12345-3100.json")
        try Data("{}".utf8).write(to: other)
        reg.cleanStale(isAlive: { _ in false })
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func tokensAreLongAndUnique() {
        let a = randomToken(), b = randomToken()
        #expect(a.count == 64)
        #expect(a != b)
    }
}
