import simd

struct LightningBolt {
    struct Branch {
        let points: [SIMD2<Float>]
        let strength: Float
    }

    let branches: [Branch]
    let impact: SIMD2<Float>
    let isTrunkClear: Bool

    init(from top: SIMD2<Float>, to impact: SIMD2<Float>, roughness: Float, random: inout FastRandom, isBlocked: (SIMD2<Float>) -> Bool) {
        self.impact = impact
        let trunk = Self.jagged(from: top, to: impact, roughness: roughness, depth: 6, random: &random)
        isTrunkClear = !trunk.contains { simd_distance($0, impact) > 4 && isBlocked($0) }
        var branches = [Branch(points: trunk, strength: 1)]
        let branchCount = random.integer(in: 3...6)
        for _ in 0..<branchCount {
            let originIndex = random.integer(in: 2...(trunk.count * 2 / 3))
            let origin = trunk[originIndex]
            let reach = simd_length(impact - top) * random.value(in: 0.12...0.35)
            let angle = random.value(in: 0.35...0.9) * (random.unit() < 0.5 ? -1 : 1)
            let end = origin + SIMD2(sin(angle), -cos(angle)) * reach
            let points = Self.jagged(from: origin, to: end, roughness: 0.28, depth: 4, random: &random)
            let visible = Array(points.prefix { !isBlocked($0) })
            guard visible.count > 1 else { continue }
            branches.append(Branch(points: visible, strength: random.value(in: 0.3...0.6)))
        }
        self.branches = branches
    }

    private static func jagged(from start: SIMD2<Float>, to end: SIMD2<Float>, roughness: Float, depth: Int, random: inout FastRandom) -> [SIMD2<Float>] {
        var points = [start, end]
        var displacement = simd_length(end - start) * roughness
        for _ in 0..<depth {
            var refined: [SIMD2<Float>] = [points[0]]
            for index in 1..<points.count {
                let a = points[index - 1]
                let b = points[index]
                let direction = b - a
                let normal = simd_normalize(SIMD2(-direction.y, direction.x) + SIMD2(0.0001, 0))
                refined.append((a + b) * 0.5 + normal * random.signedUnit() * displacement)
                refined.append(b)
            }
            points = refined
            displacement *= 0.5
        }
        return points
    }
}

struct LightningEffect {
    private static let maximumFlashAlpha: Float = 0.22
    private static let pulses: [(delay: Float, strength: Float)] = [(0, 1), (0.08, 0.45), (0.2, 0.85), (0.34, 0.3)]
    private static let reducedPulses: [(delay: Float, strength: Float)] = [(0, 0.45)]

    private var age: Float = .infinity
    private var strength: Float = 0
    private var reducesFlashing = false
    private(set) var bolt: LightningBolt?

    var isActive: Bool {
        age < 1.2
    }

    var flash: Float {
        guard isActive else { return 0 }
        let pulses = reducesFlashing ? Self.reducedPulses : Self.pulses
        let decay: Float = reducesFlashing ? 6 : 22
        let total = pulses.reduce(Float(0)) { sum, pulse in
            guard age >= pulse.delay else { return sum }
            return sum + pulse.strength * exp(-(age - pulse.delay) * decay)
        }
        return min(total, 1) * strength
    }

    var flashAlpha: Float {
        flash * Self.maximumFlashAlpha
    }

    var boltAlpha: Float {
        guard bolt != nil, age < 0.5 else { return 0 }
        return min(flash * 2.2, 1)
    }

    mutating func trigger(_ strike: LightningStrike, bolt: LightningBolt?) {
        age = 0
        strength = 1 - strike.distance * 0.7
        reducesFlashing = strike.reducesFlashing
        self.bolt = strike.reducesFlashing ? nil : bolt
    }

    mutating func advance(dt: Float) {
        guard isActive else {
            bolt = nil
            return
        }
        age += dt
    }

    func renderFlash(into segments: inout SegmentWriter, size: SIMD2<Float>) {
        let alpha = flashAlpha
        guard alpha > 0.002 else { return }
        let color = SIMD4<Float>(0.82, 0.86, 1.0, alpha)
        segments.append(from: SIMD2(size.x * 0.5, 0), to: SIMD2(size.x * 0.5, size.y), width: size.x, color: color, softness: 0, tailFade: 0.55, capStyle: .butt)
    }

    func renderBolt(into segments: inout SegmentWriter) {
        let alpha = boltAlpha
        guard let bolt, alpha > 0.01 else { return }
        for branch in bolt.branches {
            let branchAlpha = alpha * branch.strength
            let scale = 0.5 + 0.5 * branch.strength
            for index in 1..<branch.points.count {
                let a = branch.points[index - 1]
                let b = branch.points[index]
                segments.append(from: a, to: b, width: 14 * scale, color: SIMD4(0.55, 0.65, 1.0, 0.10 * branchAlpha), softness: 1)
                segments.append(from: a, to: b, width: 4 * scale, color: SIMD4(0.75, 0.82, 1.0, 0.35 * branchAlpha), softness: 0.8)
                segments.append(from: a, to: b, width: 1.6 * scale, color: SIMD4(1, 1, 1, 0.95 * branchAlpha), softness: 0.3)
            }
        }
    }
}
