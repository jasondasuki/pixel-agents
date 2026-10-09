import AppKit
import PixelMenuBarCore

/// Draws every agent's pet wandering inside one shared lane, one sprite pixel per point.
final class LaneRenderer {
    let pets: [PetSprites]
    private(set) var wanderers: [String: Wanderer] = [:]
    private var rng = SystemRandomNumberGenerator()

    /// Width of the box a pet walks in: the widest walk frame.
    let walkBoxWidth: Int
    let tallestSprite: Int

    /// Done sessions dim after this long.
    static let doneDimAfter: TimeInterval = 60

    init(pets: [PetSprites]) {
        self.pets = pets
        walkBoxWidth = pets.flatMap(\.walk).map(\.width).max() ?? 24
        tallestSprite = pets.flatMap { $0.walk + $0.idle }.map(\.height).max() ?? 22
    }

    // MARK: model

    func petFor(agentId: String, choice: PetChoice) -> PetSprites? {
        guard !pets.isEmpty else { return nil }
        switch choice {
        case .mixed: return pets[Int(stableHash(agentId) % UInt64(pets.count))]
        case let .named(name): return pets.first { $0.name == name } ?? pets[0]
        }
    }

    func step(dt: Double, agents: [Agent], now: Date, laneWidth: Double) {
        let range = 0...max(0, laneWidth - Double(walkBoxWidth))
        let live = Set(agents.map(\.id))
        wanderers = wanderers.filter { live.contains($0.key) }
        for agent in agents {
            var w = wanderers[agent.id] ?? Wanderer(
                x: Double.random(in: range, using: &rng),
                pause: Double.random(in: 0...2, using: &rng)
            )
            w.step(dt: dt, busy: agent.state.isBusy, toolRate: agent.toolRate(now: now), range: range, using: &rng)
            wanderers[agent.id] = w
        }
    }

    /// Changes whenever the picture would: used to skip identical redraws.
    func signature(agents: [Agent], now: Date, laneWidth: Double) -> Int {
        var h = Hasher()
        h.combine(Int(laneWidth))
        h.combine(Int(now.timeIntervalSinceReferenceDate * 2) % 2)   // badge blink phase
        for a in agents {
            guard let w = wanderers[a.id] else { continue }
            h.combine(a.id); h.combine(Int(w.x.rounded())); h.combine(w.frame); h.combine(w.walking)
            h.combine(w.facingRight); h.combine(a.state.rawValue); h.combine(dimmed(a, now: now))
        }
        return h.finalize()
    }

    private func dimmed(_ a: Agent, now: Date) -> Bool {
        a.state == .done && now.timeIntervalSince(a.stateSince) > Self.doneDimAfter
    }

    // MARK: drawing

    private struct Draw {
        let frame: SpriteFrame
        let x: Int
        let flip: Bool
        let alpha: CGFloat
        let badge: Badge?
        let order: Int
    }

    private enum Badge { case attention, waiting }

    /// Most attention-worthy drawn last (on top).
    private func commands(agents: [Agent], choice: PetChoice, now: Date) -> [Draw] {
        let blinkOn = Int(now.timeIntervalSinceReferenceDate * 2) % 2 == 0
        var out: [Draw] = []
        for a in agents {
            guard let pet = petFor(agentId: a.id, choice: choice), let w = wanderers[a.id] else { continue }
            let frame = w.walking ? pet.walk[w.frame % pet.walk.count] : pet.idle[w.frame % pet.idle.count]
            // Centre the frame in the walk box so idle and walk poses share a footprint.
            let x = Int(w.x.rounded()) + (walkBoxWidth - frame.width) / 2
            let badge: Badge? = a.state == .permission ? (blinkOn ? .attention : nil)
                : a.state == .waiting ? .waiting : nil
            out.append(Draw(
                frame: frame, x: x, flip: w.walking && !w.facingRight,
                alpha: dimmed(a, now: now) ? 0.7 : 1, badge: badge, order: a.state.rawValue
            ))
        }
        return out.sorted { $0.order < $1.order }
    }

    func image(agents: [Agent], choice: PetChoice, now: Date, laneWidth: Double, barHeight: Double) -> NSImage {
        let size = NSSize(width: laneWidth, height: barHeight)
        let baseline = max(0, Int((barHeight - Double(tallestSprite)) / 2))
        let draws = commands(agents: agents, choice: choice, now: now)
        let boxW = walkBoxWidth
        let sleeper = agents.isEmpty ? petFor(agentId: "sleeper", choice: choice)?.idle.first : nil

        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.interpolationQuality = .none
            ctx.setShouldAntialias(false)

            if let sleeper {
                // No agents: one dim pet, parked in the middle.
                ctx.setAlpha(0.4)
                let rect = CGRect(x: (Int(laneWidth) - sleeper.width) / 2, y: baseline, width: sleeper.width, height: sleeper.height)
                ctx.draw(sleeper.image, in: rect)
                ctx.setAlpha(1)
                return true
            }

            for d in draws {
                ctx.saveGState()
                ctx.setAlpha(d.alpha)
                let rect = CGRect(x: d.x, y: baseline, width: d.frame.width, height: d.frame.height)
                if d.flip {
                    ctx.translateBy(x: rect.midX * 2, y: 0)
                    ctx.scaleBy(x: -1, y: 1)
                }
                ctx.draw(d.frame.image, in: rect)
                ctx.restoreGState()
                if let badge = d.badge {
                    Self.drawBadge(badge, in: ctx, right: d.x + (boxW + d.frame.width) / 2, top: Int(barHeight))
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// 1pt-per-pixel glyphs in the top-right corner, with a dark outline so they read on any bar.
    private static func drawBadge(_ badge: Badge, in ctx: CGContext, right: Int, top: Int) {
        let pixels: [(Int, Int)]
        let color: CGColor
        switch badge {
        case .attention:   // "!"
            pixels = [(0, 0), (0, 1), (0, 2), (0, 4)]
            color = CGColor(red: 1, green: 0.69, blue: 0, alpha: 1)
        case .waiting:     // "..."
            pixels = [(0, 0), (2, 0), (4, 0)]
            color = CGColor(red: 0.30, green: 0.85, blue: 0.39, alpha: 1)
        }
        let w = (pixels.map(\.0).max() ?? 0) + 1
        let h = (pixels.map(\.1).max() ?? 0) + 1
        let ox = right - w - 1
        let oy = top - h - 2   // glyph rows count down from the top edge
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.85))
        for (px, py) in pixels {
            ctx.fill(CGRect(x: ox + px - 1, y: oy + (h - 1 - py) - 1, width: 3, height: 3))
        }
        ctx.setFillColor(color)
        for (px, py) in pixels {
            ctx.fill(CGRect(x: ox + px, y: oy + (h - 1 - py), width: 1, height: 1))
        }
    }
}

enum PetChoice: Equatable {
    case mixed
    case named(String)

    init(stored: String?) {
        guard let stored, stored != "mixed" else { self = .mixed; return }
        self = .named(stored)
    }

    var stored: String {
        switch self {
        case .mixed: return "mixed"
        case let .named(name): return name
        }
    }
}

/// FNV-1a, so a session keeps its pet across launches (Swift's Hasher is seeded per process).
func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}
