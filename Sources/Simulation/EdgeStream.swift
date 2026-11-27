import simd

enum EdgeSide {
    case left
    case right
    case face
}

struct RivuletSlug {
    var distance: Float
    var speed: Float
    var targetSpeed: Float
    var baseLength: Float
    var volume: Float
    var pinnedTime: Float = 0
    var jitterTime: Float = 0
    var isResidue = false

    var isPinned: Bool {
        isResidue || pinnedTime > 0
    }

    var sizeFactor: Float {
        (volume / EdgeStream.dripVolume).squareRoot().clamped(to: 0.35...1.6)
    }

    var length: Float {
        guard !isResidue else { return 0.5 }
        let stretch: Float = pinnedTime > 0 ? 0.35 : 1
        return max(min(baseLength * sizeFactor, 22) * stretch, 2)
    }

    var contactReach: Float {
        max(length * 0.35, 1.2)
    }

    static func slidingSpeed(forVolume volume: Float) -> Float {
        (165 * (volume / EdgeStream.dripVolume).squareRoot()).clamped(to: 60...340)
    }
}

struct EdgeStream {
    static let dripVolume: Float = 3.5
    static let maximumSlugs = 24
    static let maximumResidue = 30
    static let slugsPerSecondAtFullFlow: Float = 12
    static let residueVolume: Float = 0.25
    static let residueEvaporation: Float = 0.03
    static let mergeBoost: Float = 70

    let side: EdgeSide
    let phase: Float
    private(set) var flow: Float = 0
    private(set) var pendingVolume: Float = 0
    private(set) var wetness: Float = 0
    private(set) var wetLength: Float = 0
    private(set) var slugs: [RivuletSlug] = []
    private(set) var axisX: Float = 0
    private(set) var topY: Float = 0
    private(set) var bottomY: Float = 0
    private(set) var surfaceOrder = 0
    private(set) var arcCenter = SIMD2<Float>.zero
    private(set) var arcRadius: Float = 0

    init(side: EdgeSide, phase: Float) {
        self.side = side
        self.phase = phase
    }

    var arcLength: Float {
        arcRadius * .pi * 0.5
    }

    var length: Float {
        guard arcRadius > 0 else { return max(topY - bottomY, 0) }
        return arcLength + max(arcCenter.y - bottomY, 0)
    }

    func point(atDistance distance: Float) -> SIMD2<Float> {
        guard arcRadius > 0 else { return straightPoint(fromY: topY, distance: distance) }
        guard distance < arcLength else { return straightPoint(fromY: arcCenter.y, distance: distance - arcLength) }
        let sweep = distance / arcRadius
        let angle = Float.pi * 0.5 + (side == .left ? sweep : -sweep)
        return arcCenter + SIMD2(cos(angle), sin(angle)) * arcRadius
    }

    private func straightPoint(fromY startY: Float, distance: Float) -> SIMD2<Float> {
        let y = startY - distance
        let settle = min(distance / 14, 1)
        return SIMD2(axisX + meander(atY: y) * settle, y)
    }

    var isActive: Bool {
        wetLength > 1 || !slugs.isEmpty
    }

    private var hasMovingWater: Bool {
        slugs.contains { !$0.isResidue }
    }

    private var movingCount: Int {
        slugs.reduce(0) { $0 + ($1.isResidue ? 0 : 1) }
    }

    private var residueCount: Int {
        slugs.count - movingCount
    }

    var slugVolume: Float {
        max(Self.dripVolume, flow / Self.slugsPerSecondAtFullFlow)
    }

    var pendantFraction: Float {
        min(pendingVolume / slugVolume, 1)
    }

    var trailOpacity: Float {
        wetness * (0.05 + 0.09 * min(flow / 30, 1))
    }

    var trailWidth: Float {
        0.9 + 0.6 * min(flow / 30, 1)
    }

    mutating func receive(volume: Float, dt: Float) {
        let instantaneous = volume / max(dt, 0.0001)
        flow += (instantaneous - flow) * min(dt * 3, 1)
        pendingVolume += volume
    }

    mutating func route(axisX: Float, topY: Float, bottomY: Float, surfaceOrder: Int, corner: WindowSurface? = nil) {
        if let corner {
            let inset = corner.radius
            let centerX = side == .left ? corner.minX + inset : corner.maxX - inset
            arcCenter = SIMD2(centerX, corner.maxY - inset)
            arcRadius = inset + abs(axisX - (side == .left ? corner.minX : corner.maxX))
        } else {
            arcRadius = 0
        }
        self.axisX = axisX
        self.topY = topY
        self.bottomY = bottomY
        self.surfaceOrder = surfaceOrder
    }

    mutating func advance(dt: Float, random: inout FastRandom, arrive: (Float) -> Void) {
        updateWetness(dt: dt)
        releaseSlugIfReady(random: &random)
        moveSlugs(dt: dt, random: &random, arrive: arrive)
        wetLength = min(wetLength, length)
        if wetness <= 0 && slugs.isEmpty && flow < 0.15 {
            wetLength = 0
            pendingVolume = 0
        }
    }

    mutating func reset() {
        flow = 0
        pendingVolume = 0
        wetness = 0
        wetLength = 0
        slugs.removeAll(keepingCapacity: true)
    }

    func meander(atY y: Float) -> Float {
        guard side == .face else {
            return 0.9 * sin(y * 0.021 + phase) + 0.35 * sin(y * 0.057 + phase * 2.3)
        }
        let wander = 3.2 * sin(y * 0.011 + phase) + 1.6 * sin(y * 0.029 + phase * 1.7)
        let wobble = 0.7 * sin(y * 0.083 + phase * 3.1) + 0.3 * sin(y * 0.19 + phase * 5.3)
        return wander + wobble
    }

    static func axisX(for side: EdgeSide, surface: WindowSurface) -> Float {
        let offset: Float = 2.2
        switch side {
        case .left: return surface.minX - offset
        case .right: return surface.maxX + offset
        case .face: return (surface.minX + surface.maxX) * 0.5
        }
    }

    private mutating func updateWetness(dt: Float) {
        if !hasMovingWater {
            wetness = max(wetness - dt * 0.3, 0)
        } else {
            wetness = min(wetness + dt * 3, 1)
        }
    }

    private mutating func releaseSlugIfReady(random: inout FastRandom) {
        let slugVolume = self.slugVolume
        guard pendingVolume >= slugVolume, movingCount < Self.maximumSlugs else { return }
        pendingVolume -= slugVolume
        slugs.append(RivuletSlug(
            distance: 0,
            speed: 0,
            targetSpeed: RivuletSlug.slidingSpeed(forVolume: slugVolume),
            baseLength: random.value(in: 7...13),
            volume: slugVolume,
            pinnedTime: random.value(in: 0.05...0.35)
        ))
    }

    private mutating func moveSlugs(dt: Float, random: inout FastRandom, arrive: (Float) -> Void) {
        let total = length
        var index = 0
        while index < slugs.count {
            var slug = slugs[index]
            if slug.isResidue {
                slug.volume -= Self.residueEvaporation * dt
            } else {
                slide(&slug, dt: dt, random: &random)
                shedResidue(from: &slug, dt: dt, random: &random)
                wetLength = max(wetLength, min(slug.distance, total))
            }
            if slug.volume <= 0 {
                slugs.remove(at: index)
                continue
            }
            if !slug.isResidue && slug.distance >= total {
                arrive(slug.volume)
                slugs.remove(at: index)
                continue
            }
            slugs[index] = slug
            index += 1
        }
        mergeTouchingSlugs()
    }

    private func slide(_ slug: inout RivuletSlug, dt: Float, random: inout FastRandom) {
        if slug.pinnedTime > 0 {
            slug.pinnedTime -= dt
            slug.speed = 0
            return
        }
        slug.jitterTime -= dt
        if slug.jitterTime <= 0 {
            slug.targetSpeed = RivuletSlug.slidingSpeed(forVolume: slug.volume) * random.value(in: 0.55...1.3)
            slug.jitterTime = random.value(in: 0.06...0.25)
        }
        slug.speed += (slug.targetSpeed - slug.speed) * min(dt * 7, 1)
        slug.distance += slug.speed * dt
        if random.unit() < pinningRate(for: slug) * dt {
            slug.pinnedTime = random.value(in: 0.15...1.4) / slug.sizeFactor
            slug.speed = 0
        }
    }

    private func pinningRate(for slug: RivuletSlug) -> Float {
        let isOnDryGlass = slug.distance >= wetLength - 2
        let baseRate: Float = isOnDryGlass ? 1.6 : 0.12
        return baseRate / (slug.sizeFactor * slug.sizeFactor)
    }

    private mutating func shedResidue(from slug: inout RivuletSlug, dt: Float, random: inout FastRandom) {
        guard slug.pinnedTime <= 0, slug.volume > Self.residueVolume * 4, residueCount < Self.maximumResidue else { return }
        guard random.unit() < 0.9 * dt else { return }
        slug.volume -= Self.residueVolume
        slugs.append(RivuletSlug(
            distance: max(slug.distance - slug.length, 0),
            speed: 0,
            targetSpeed: 0,
            baseLength: 0,
            volume: Self.residueVolume,
            isResidue: true
        ))
    }

    private mutating func mergeTouchingSlugs() {
        guard slugs.count > 1 else { return }
        slugs.sort { $0.distance > $1.distance }
        var index = 1
        while index < slugs.count {
            let leader = slugs[index - 1]
            let follower = slugs[index]
            let touches = leader.distance - follower.distance < leader.contactReach + follower.sizeFactor
            guard touches, !(leader.isResidue && follower.isResidue) else {
                index += 1
                continue
            }
            slugs[index - 1] = merged(leader, follower)
            slugs.remove(at: index)
        }
    }

    private func merged(_ leader: RivuletSlug, _ follower: RivuletSlug) -> RivuletSlug {
        let mover = leader.isResidue ? follower : leader
        var result = mover
        result.distance = leader.distance
        result.volume = leader.volume + follower.volume
        result.isResidue = false
        result.pinnedTime = 0
        result.baseLength = max(leader.baseLength, follower.baseLength)
        result.speed = max(leader.speed, follower.speed) + Self.mergeBoost * (follower.volume / result.volume).squareRoot()
        result.targetSpeed = RivuletSlug.slidingSpeed(forVolume: result.volume)
        result.jitterTime = 0.15
        return result
    }
}
