import CoreGraphics
import Foundation

/// Body joints JumpShot uses. Points are in frame pixels, y grows downward.
enum Joint: CaseIterable {
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

typealias Pose = [Joint: CGPoint]

/// Same algorithm as the Android app's JumpDetector.kt and the web app's detector.js.
///
/// Tracks the hip midpoint. Distances are in "torso lengths" (shoulder-mid to
/// hip-mid, learned while standing), so thresholds work at any distance.
///  - learning: person stands still ~0.4 s → baseline hip height learned
///  - ready:    watching; a crouch below the baseline is remembered as a dip
///  - trigger:  push-off = after a dip, hips move up fast (before the feet leave the ground)
///              airborne = hips clearly above stance and still rising
///  - cooldown: ignore landing / bouncing
final class JumpDetector {
    enum Mode { case pushOff, airborne }
    enum State { case noPerson, learning, ready, dipping, cooldown, disarmed }

    struct Result {
        var state: State
        var triggered = false
        var hip: CGPoint?
        var baselineY: CGFloat?
        var riseLineY: CGFloat?
        var dipLineY: CGFloat?
        /// Hip height above stance, torso lengths (negative = crouched).
        var rise: CGFloat = 0
        /// Upward hip speed, torso lengths per second.
        var vUp: CGFloat = 0
    }

    var mode: Mode = .pushOff
    /// 0 = hard to trigger, 1 = very easy.
    var sensitivity: CGFloat = 0.5
    var cooldown: Double = 2

    private struct Sample { let t: Double; let hip: CGFloat; let torso: CGFloat }

    private var samples: [Sample] = []
    private var baseline: CGFloat?
    private var torsoRef: CGFloat = 0
    private var farStableSince: Double?
    private var lastDip = JumpDetector.never
    private var lastSeen = JumpDetector.never
    private var cooldownUntil = JumpDetector.never

    private static let never = -1e9
    private static let minTorsoPx: CGFloat = 15
    private static let history = 1.5
    private static let lostReset = 0.5
    private static let stableWindow = 0.5
    private static let stableMinSpan = 0.35
    private static let stableRange: CGFloat = 0.06
    private static let relearnTolerance: CGFloat = 0.15
    private static let relearnAfter = 1.5
    private static let dipMemory = 1.0
    private static let velocitySpan = 0.06

    func reset() {
        samples.removeAll()
        baseline = nil
        farStableSince = nil
        lastDip = Self.never
    }

    func update(_ pose: Pose, time t: Double, armed: Bool) -> Result {
        guard let ls = pose[.leftShoulder], let rs = pose[.rightShoulder],
              let lh = pose[.leftHip], let rh = pose[.rightHip] else { return lost(t) }

        let hip = CGPoint(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2)
        let sh = CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
        let torso = hypot(sh.x - hip.x, sh.y - hip.y)
        if torso < Self.minTorsoPx { return lost(t) }
        lastSeen = t

        samples.append(Sample(t: t, hip: hip.y, torso: torso))
        while let first = samples.first, first.t < t - Self.history { samples.removeFirst() }

        if t >= cooldownUntil { updateBaseline(t) }
        guard let base = baseline else { return Result(state: .learning, hip: hip) }

        let s = min(1, max(0, sensitivity))
        let dipThr = lerp(0.25, 0.08, s)
        let riseThr = lerp(0.30, 0.10, s)
        let pushVel = lerp(3.0, 1.2, s)
        let liftVel = lerp(1.5, 0.5, s)

        let rise = (base - hip.y) / torsoRef
        let vUp = upwardVelocity()
        if rise < -dipThr { lastDip = t }
        let dipped = t - lastDip < Self.dipMemory

        func result(_ state: State, _ triggered: Bool = false) -> Result {
            Result(state: state, triggered: triggered, hip: hip, baselineY: base,
                   riseLineY: base - riseThr * torsoRef,
                   dipLineY: mode == .pushOff ? base + dipThr * torsoRef : nil,
                   rise: rise, vUp: vUp)
        }

        if !armed { return result(.disarmed) }
        if t < cooldownUntil { return result(.cooldown) }

        let pushOff = mode == .pushOff && dipped && vUp > pushVel
        let lifted = rise > riseThr && vUp > liftVel
        if pushOff || lifted {
            cooldownUntil = t + cooldown
            lastDip = Self.never
            return result(.ready, true)
        }
        return result(dipped ? .dipping : .ready)
    }

    private func lost(_ t: Double) -> Result {
        if t - lastSeen > Self.lostReset { reset() }
        return Result(state: .noPerson)
    }

    /// Learn / refresh the standing hip height whenever the person holds still.
    private func updateBaseline(_ t: Double) {
        let win = samples.filter { $0.t >= t - Self.stableWindow }
        guard win.count >= 4, let first = win.first, t - first.t >= Self.stableMinSpan else { return }
        let torsoMed = median(win.map(\.torso))
        let hips = win.map(\.hip)
        guard let hMax = hips.max(), let hMin = hips.min() else { return }
        if hMax - hMin > Self.stableRange * torsoMed {
            farStableSince = nil
            return
        }
        let cand = median(hips)
        if baseline == nil || abs(cand - baseline!) < Self.relearnTolerance * torsoRef {
            baseline = cand; torsoRef = torsoMed; farStableSince = nil
        } else {
            // Holding a different height (e.g. a squat): only accept it after a while.
            let since = farStableSince ?? t
            farStableSince = since
            if t - since > Self.relearnAfter {
                baseline = cand; torsoRef = torsoMed; farStableSince = nil
            }
        }
    }

    private func upwardVelocity() -> CGFloat {
        guard samples.count >= 2, torsoRef > 0, let cur = samples.last else { return 0 }
        for s in samples.dropLast().reversed() {
            let dt = cur.t - s.t
            if dt >= Self.velocitySpan {
                return dt > 0.3 ? 0 : (s.hip - cur.hip) / torsoRef / CGFloat(dt)
            }
        }
        return 0
    }

    private func median(_ v: [CGFloat]) -> CGFloat { v.sorted()[v.count / 2] }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ s: CGFloat) -> CGFloat { a + (b - a) * s }
}
