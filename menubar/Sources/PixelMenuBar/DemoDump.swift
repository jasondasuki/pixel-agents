import AppKit
import PixelMenuBarCore

/// Renders the lane at several agent counts on a light and a dark bar, 6x, plus the raw frames.
@MainActor
enum DemoDump {
    static let scale = 6.0
    static let barHeight = 24.0

    static func run(path: String) -> Int32 {
        let pets = PetLoader.loadAll()
        guard !pets.isEmpty else {
            FileHandle.standardError.write(Data("no pets found in \(PetLoader.resourceDirectory.path)\n".utf8))
            return 1
        }
        let renderer = LaneRenderer(pets: pets)
        let now = Date()

        func scenario(_ n: Int, states: [String]) -> [Agent] {
            let store = AgentStore()
            for i in 0..<n {
                let id = "demo-\(i)", cwd = "/work/project\(i)"
                func send(_ e: AgentEvent) { store.apply(NormalizedHook(sessionId: id, cwd: cwd, event: e), now: now) }
                switch states[i % states.count] {
                case "working": send(.toolStart(name: "Edit", label: "Editing a.ts"))
                case "permission": send(.permissionRequest)
                case "waiting": send(.turnEnd(awaitingInput: true))
                case "done": send(.turnEnd(awaitingInput: false))
                default: send(.sessionStart)
                }
            }
            return store.sorted()
        }

        let scenarios: [(String, [Agent])] = [
            ("0 agents", []),
            ("1 working", scenario(1, states: ["working"])),
            ("1 permission", scenario(1, states: ["permission"])),
            ("1 waiting", scenario(1, states: ["waiting"])),
            ("4 mixed", scenario(4, states: ["working", "permission", "waiting", "done"])),
            ("15 agents (capped)", scenario(15, states: ["working", "done", "waiting", "permission"])),
        ]

        let laneMax = scenarios.map { laneWidth(agentCount: $0.1.count) }.max() ?? 260
        let rowH = Int(barHeight * scale) + 8
        let sheetRows = pets.count
        let width = Int(laneMax * scale) * 2 + 60
        let height = rowH * scenarios.count + (Int(34 * scale) + 8) * sheetRows + 16
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return 1 }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        let cg = gctx.cgContext
        cg.setFillColor(CGColor(gray: 0.5, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let backgrounds = [CGColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1), CGColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)]
        var y = height - 4
        for (_, agents) in scenarios {
            y -= rowH
            let lw = laneWidth(agentCount: agents.count)
            // Let the pets spread out so the lane is not all at x=0.
            for _ in 0..<(12 * 20) { renderer.step(dt: 1.0 / 12, agents: agents, now: now, laneWidth: lw) }
            let image = renderer.image(agents: agents, choice: .mixed, now: now, laneWidth: lw, barHeight: barHeight)
            for (b, bg) in backgrounds.enumerated() {
                let x = 10 + b * (Int(laneMax * scale) + 20)
                let rect = CGRect(x: x, y: y, width: Int(lw * scale), height: Int(barHeight * scale))
                cg.setFillColor(bg)
                cg.fill(CGRect(x: x, y: y, width: Int(laneMax * scale), height: Int(barHeight * scale)))
                cg.saveGState()
                cg.translateBy(x: rect.minX, y: rect.minY)
                cg.scaleBy(x: scale, y: scale)
                image.draw(in: CGRect(x: 0, y: 0, width: lw, height: barHeight))
                cg.restoreGState()
            }
        }

        // Raw frames: walk cells, then idle cells, per pet.
        for pet in pets {
            y -= Int(34 * scale) + 8
            var x = 10
            for frame in pet.walk + pet.idle {
                let r = CGRect(x: x, y: y, width: Int(Double(frame.width) * scale), height: Int(Double(frame.height) * scale))
                cg.setFillColor(backgrounds[x % 2 == 0 ? 0 : 1])
                cg.fill(r.insetBy(dx: -2, dy: -2))
                cg.interpolationQuality = .none
                cg.draw(frame.image, in: r)
                x += Int(Double(frame.width) * scale) + 12
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            return 1
        }
        for pet in pets {
            let walk = pet.walk.map { "\($0.width)x\($0.height)" }.joined(separator: ",")
            let idle = pet.idle.map { "\($0.width)x\($0.height)" }.joined(separator: ",")
            print("\(pet.name): walk \(walk) idle \(idle)")
        }
        print("wrote \(path)")
        return 0
    }
}
