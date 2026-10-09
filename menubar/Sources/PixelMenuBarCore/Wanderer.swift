import Foundation

/// 1-D wander model, loosely after the pet AI in webview-ui/src/office/engine/petEntity.ts
/// (pause, pick a target, walk), with eased starts and stops, strolls of several legs and a
/// bias toward long walks so the pet covers the whole lane.
public enum WanderTuning {
    public static let walkSequence = [0, 1, 0, 2]
    public static let idleSequence = [0, 1, 2, 1]
    /// Walk frame time at `calmSpeed`; faster walks cycle proportionally faster so the feet match the ground.
    public static let walkFrameDuration = 0.15
    public static let idleFrameDuration = 0.3

    /// Ground speed the walk frames are drawn for; slower or faster walks scale the feet to match.
    public static let referenceSpeed = 32.0
    /// Idle sessions amble slowly, like they would rather not.
    public static let calmSpeed = 20.0
    public static let busyBaseSpeed = 64.0
    public static let busyMaxSpeed = 96.0
    /// Each leg's cruise speed varies by this much, so no two walks look the same.
    public static let speedJitter: ClosedRange<Double> = 0.8...1.2

    public static let acceleration = 80.0     // pt/s^2
    public static let deceleration = 110.0
    /// Below this the walk is a shuffle; the pet settles instead of creeping the last point.
    public static let minWalkSpeed = 8.0

    /// Idle sessions rest a long time between walks, so the pet looks lazy.
    public static let calmPause: ClosedRange<Double> = 25.0...90.0
    /// First rest of a pet that appears while its session is idle.
    public static let calmFirstPause: ClosedRange<Double> = 10.0...40.0
    public static let busyPause: ClosedRange<Double> = 0.4...1.6
    /// Short look-around between the legs of one stroll.
    public static let betweenLegs: ClosedRange<Double> = 0.3...1.0
    public static let calmLegs = 1...1
    public static let busyLegs = 2...4

    /// A leg covers at least this share of the walkable span (when there is room).
    public static let minLegShare = 0.35
    /// <1 skews leg length toward the far end of the available room.
    public static let legLengthBias = 0.6
}

public struct Wanderer {
    /// Left edge of the walk-sized box, in lane points.
    public private(set) var x: Double
    public private(set) var facingRight = true
    public private(set) var walking = false
    /// Current ground speed in pt/s (0 while paused).
    public private(set) var speed = 0.0
    private var cruise = 0.0
    private var target: Double
    private var legsLeft = 0
    private var wasBusy = false
    private var pauseLeft: Double
    private var animTime = 0.0

    public init(x: Double, pause: Double) {
        self.x = x
        self.target = x
        self.pauseLeft = pause
    }

    /// Index into the 3-frame walk or idle strip for the current moment.
    public var frame: Int {
        if walking {
            let i = Int(animTime / WanderTuning.walkFrameDuration) % WanderTuning.walkSequence.count
            return WanderTuning.walkSequence[i]
        }
        let i = Int(animTime / WanderTuning.idleFrameDuration) % WanderTuning.idleSequence.count
        return WanderTuning.idleSequence[i]
    }

    /// `range` is the walkable span of `x`. `toolRate` is tool starts in the last 10s (busy only).
    public mutating func step(
        dt: Double,
        busy: Bool,
        toolRate: Int,
        range: ClosedRange<Double>,
        using rng: inout some RandomNumberGenerator
    ) {
        // Lane can shrink under a pet when agents leave.
        x = min(max(x, range.lowerBound), range.upperBound)

        // Work just ended: a short busy-time pause becomes a long rest instead of one more quick walk.
        if wasBusy, !busy, !walking {
            pauseLeft = max(pauseLeft, Double.random(in: WanderTuning.calmPause, using: &rng))
        }
        wasBusy = busy

        if walking {
            walk(dt: dt, busy: busy, range: range, using: &rng)
        } else {
            animTime += dt
            pauseLeft -= dt
            guard pauseLeft <= 0 else { return }
            guard range.upperBound - range.lowerBound > 1 else { pauseLeft = 1; return }
            startLeg(busy: busy, toolRate: toolRate, range: range, using: &rng)
        }
    }

    private mutating func walk(dt: Double, busy: Bool, range: ClosedRange<Double>, using rng: inout some RandomNumberGenerator) {
        // The lane may have shrunk since this leg was planned.
        target = min(max(target, range.lowerBound), range.upperBound)
        let remaining = abs(target - x)
        let direction: Double = target >= x ? 1 : -1

        // Ease out when the stopping distance reaches the remaining distance, otherwise ease up to cruise.
        let braking = speed * speed / (2 * WanderTuning.deceleration)
        if remaining <= braking {
            speed = max(WanderTuning.minWalkSpeed, speed - WanderTuning.deceleration * dt)
        } else {
            speed = min(cruise, speed + WanderTuning.acceleration * dt)
        }

        // Feet follow the ground: frame rate scales with speed.
        animTime += dt * max(speed, WanderTuning.minWalkSpeed) / WanderTuning.referenceSpeed

        let move = speed * dt
        if move >= remaining {
            x = target
            arrive(busy: busy, using: &rng)
        } else {
            x += direction * move
        }
    }

    private mutating func arrive(busy: Bool, using rng: inout some RandomNumberGenerator) {
        walking = false
        speed = 0
        animTime = 0
        legsLeft = busy ? legsLeft - 1 : 0   // an idle pet does not chain walks
        pauseLeft = legsLeft > 0
            ? Double.random(in: WanderTuning.betweenLegs, using: &rng)
            : Double.random(in: busy ? WanderTuning.busyPause : WanderTuning.calmPause, using: &rng)
    }

    private mutating func startLeg(busy: Bool, toolRate: Int, range: ClosedRange<Double>, using rng: inout some RandomNumberGenerator) {
        if legsLeft <= 0 {
            legsLeft = Int.random(in: busy ? WanderTuning.busyLegs : WanderTuning.calmLegs, using: &rng)
        }

        let span = range.upperBound - range.lowerBound
        let leftRoom = x - range.lowerBound
        let rightRoom = range.upperBound - x
        let minLeg = min(max(8, span * WanderTuning.minLegShare), max(leftRoom, rightRoom))

        // Walk toward a side with room for a proper leg, weighted by how much room it has.
        let rightOK = rightRoom >= minLeg, leftOK = leftRoom >= minLeg
        let goRight: Bool
        switch (leftOK, rightOK) {
        case (true, true): goRight = Double.random(in: 0...(leftRoom + rightRoom), using: &rng) < rightRoom
        case (false, true): goRight = true
        case (true, false): goRight = false
        case (false, false): goRight = rightRoom >= leftRoom
        }
        let room = goRight ? rightRoom : leftRoom
        let share = pow(Double.random(in: 0...1, using: &rng), WanderTuning.legLengthBias)
        let distance = min(room, minLeg + (room - minLeg) * share)

        target = x + (goRight ? distance : -distance)
        facingRight = goRight

        let base = busy
            ? min(WanderTuning.busyMaxSpeed, WanderTuning.busyBaseSpeed + Double(toolRate) * 4)
            : WanderTuning.calmSpeed
        cruise = base * Double.random(in: WanderTuning.speedJitter, using: &rng)
        speed = 0
        walking = true
        animTime = 0
    }
}

/// How wide the status item's lane is.
public enum LaneSetting: Equatable {
    /// 120pt for one session, +30pt per extra, up to 320pt.
    case auto
    /// Always this wide while any session exists, however many there are.
    case fixed(Double)

    public static let presets: [LaneSetting] = [.auto, .fixed(160), .fixed(240), .fixed(320), .fixed(480), .fixed(640)]
    public static let `default` = LaneSetting.fixed(320)

    /// UserDefaults value: nil = never chosen, 0 = auto, otherwise a fixed width.
    public init(stored: Double?) {
        guard let stored else { self = .default; return }
        self = stored <= 0 ? .auto : .fixed(stored)
    }

    public var stored: Double {
        switch self {
        case .auto: return 0
        case let .fixed(width): return width
        }
    }

    public var title: String {
        switch self {
        case .auto: return "Grow with sessions"
        case let .fixed(width): return "\(Int(width)) pt"
        }
    }
}

/// Lane width in points. `screenLimit` keeps the item from crowding other menu bar icons out.
public func laneWidth(agentCount n: Int, setting: LaneSetting = .auto, screenLimit: Double = .infinity) -> Double {
    guard n > 0 else { return 32 }
    switch setting {
    case .auto:
        return min(screenLimit, growingLaneWidth(agentCount: n))
    case let .fixed(width):
        return min(screenLimit, width)
    }
}

/// The growing lane: one pet gets a wide lane to roam, each extra agent adds a little, capped.
public func growingLaneWidth(agentCount n: Int, base: Double = 120, perAgent: Double = 30, max maxWidth: Double = 320) -> Double {
    guard n > 0 else { return 32 }
    return min(maxWidth, base + perAgent * Double(n - 1))
}
