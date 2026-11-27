import CoreGraphics
import simd

final class RainSimulation {
    private(set) var size: SIMD2<Float>
    private var configuration: SimulationConfiguration
    private var random = FastRandom()
    private var drops: [FallingDrop] = []
    private var splashes: [SplashParticle] = []
    private var scene = SurfaceScene()
    private let puddles = PuddleSystem()
    private let pool: BottomPool
    private var cursorInfluence = CursorInfluence()
    private var activeCursor: CursorSample?
    private var time: Float = 0
    private var spawnAccumulator: Float = 0
    private var liveRainCount = 0
    private var lightning = LightningEffect()
    private var windStrength: Float = 0
    private var windColumns = [WindSample](repeating: .calm, count: RainSimulation.windColumnCount + 1)
    private var splashPush = [Float](repeating: 0, count: RainSimulation.windColumnCount + 1)
    private static let windColumnCount = 24
    private let splashGravity: Float = 1400

    init(size: SIMD2<Float>, configuration: SimulationConfiguration) {
        self.size = size
        self.configuration = configuration
        self.pool = BottomPool(width: size.x, maximumLevel: configuration.poolMaximumFraction * size.y)
        pool.isEnabled = configuration.isPoolEnabled
        drops.reserveCapacity(configuration.maximumDropCount + 512)
        splashes.reserveCapacity(configuration.splashCapacity)
    }

    var diagnosticSummary: String {
        "drops=\(drops.count) splashes=\(splashes.count) surfaces=\(scene.surfaces.count) spans=\(scene.spans.count) puddles=\(puddles.count) poolLevel=\(String(format: "%.1f", pool.level)) faceFlow=\(String(format: "%.1f", puddles.faceFlow)) deepestPuddle=\(String(format: "%.2f", puddles.deepestPuddle))"
    }

    func resize(to newSize: SIMD2<Float>) {
        size = newSize
        pool.resize(to: newSize.x)
        pool.maximumLevel = configuration.poolMaximumFraction * newSize.y
    }

    func apply(_ newConfiguration: SimulationConfiguration) {
        configuration = newConfiguration
        pool.isEnabled = newConfiguration.isPoolEnabled
        pool.maximumLevel = newConfiguration.poolMaximumFraction * size.y
    }

    func step(dt: Float, time clock: Double, windows: [WindowRecord], screenOrigin: SIMD2<Float>, cursor: CursorSample?) {
        time += dt
        lightning.advance(dt: dt)
        updateWind(dt: dt, clock: clock, originX: screenOrigin.x)
        activeCursor = configuration.isCursorInteractionEnabled ? cursor : nil
        scene.rebuild(from: windows, screenOrigin: screenOrigin, screenSize: size, waterline: pool.isVisible ? pool.level : 0)
        puddles.synchronize(with: scene)
        collectEmittedDrops()
        spawnRain(dt: dt)
        updateDrops(dt: dt)
        updateSplashes(dt: dt)
        puddles.step(dt: dt, scene: scene, floorHeight: pool.surfaceHeight(atX:))
        collectEmittedDrops()
        stirPool(dt: dt)
        chopPool(dt: dt)
        pool.step(dt: dt)
    }

    private func updateWind(dt: Float, clock: Double, originX: Float) {
        windStrength += (configuration.wind - windStrength) * min(dt * 1.5, 1)
        let field = WindField(strength: windStrength)
        for column in windColumns.indices {
            let x = size.x * Float(column) / Float(Self.windColumnCount)
            let sample = field.sample(at: clock, x: originX + x)
            windColumns[column] = sample
            splashPush[column] = sin(sample.angle) * 520 * windStrength
        }
    }

    private func windColumn(atX x: Float) -> Int {
        let position = x / size.x * Float(Self.windColumnCount) + 0.5
        return Int(position.clamped(to: 0...Float(Self.windColumnCount)))
    }

    private func wind(atX x: Float) -> WindSample {
        let position = (x / size.x * Float(Self.windColumnCount)).clamped(to: 0...Float(Self.windColumnCount))
        let lower = min(Int(position), Self.windColumnCount - 1)
        let fraction = position - Float(lower)
        let a = windColumns[lower]
        let b = windColumns[lower + 1]
        return WindSample(
            angle: a.angle + (b.angle - a.angle) * fraction,
            gust: a.gust + (b.gust - a.gust) * fraction,
            direction: a.direction + (b.direction - a.direction) * fraction
        )
    }

    private func chopPool(dt: Float) {
        guard pool.isVisible else { return }
        let gust = wind(atX: size.x * 0.5).gust
        guard gust > 0.2, random.unit() < (gust - 0.2) * 14 * dt else { return }
        pool.disturb(atX: random.value(in: 0...size.x), strength: 25 + 70 * gust, radius: random.value(in: 6...14))
    }

    private func stirPool(dt: Float) {
        guard let entry = cursorInfluence.stir(pool, with: activeCursor, dt: dt) else { return }
        spawnSplashes(at: entry, incoming: SIMD2(0, -600), count: random.integer(in: 4...7), strength: 0.9)
    }

    private func collectEmittedDrops() {
        drops.append(contentsOf: puddles.emittedDrops)

        puddles.clearEmitted()
    }

    func render(segments: inout SegmentWriter, water: inout WaterStripWriter) {
        lightning.renderFlash(into: &segments, size: size)
        pool.render(into: &water)
        puddles.renderWater(into: &water, scene: scene)
        puddles.renderStreams(into: &segments, scene: scene, time: time)
        renderDrops(into: &segments)
        renderSplashes(into: &segments)
        lightning.renderBolt(into: &segments)
    }

    func prefillPool(fraction: Float) {
        pool.prefill(level: fraction * size.y)
    }

    func strike(_ strike: LightningStrike, showsBolt: Bool) {
        let bolt = showsBolt && strike.showsBolt ? makeBolt(seed: strike.seed) : nil
        lightning.trigger(strike, bolt: bolt)
        guard let bolt else { return }
        spawnSplashes(at: bolt.impact, incoming: SIMD2(0, -900), count: 18, strength: 1)
        if bolt.impact.y <= pool.surfaceHeight(atX: bolt.impact.x) + 1 {
            pool.disturb(atX: bolt.impact.x, strength: 160, radius: 18)
        }
    }

    private func makeBolt(seed: UInt64) -> LightningBolt? {
        var boltRandom = FastRandom(seed: seed)
        let isBlocked: (SIMD2<Float>) -> Bool = { [scene] point in scene.isOccluded(point, inFrontOf: .max) }
        for attempt in 0..<10 {
            let x = boltRandom.value(in: (size.x * 0.1)...(size.x * 0.9))
            let ground = scene.highestEdge(atX: x, below: size.y - 80, above: 0, excluding: 0) ?? pool.surfaceHeight(atX: x)
            let sway = size.x * 0.06
            let top = SIMD2(x + boltRandom.value(in: -sway...sway), size.y + 10)
            let roughness = 0.2 * (1 - Float(attempt) * 0.08)
            let bolt = LightningBolt(from: top, to: SIMD2(x, ground + 0.5), roughness: roughness, random: &boltRandom, isBlocked: isBlocked)
            if bolt.isTrunkClear { return bolt }
        }
        return nil
    }

    private var lightBoost: Float {
        1 + 1.6 * lightning.flash
    }

    private func spawnRain(dt: Float) {
        let slope = tan(wind(atX: size.x * 0.5).angle)
        let sideFlux = abs(slope) * size.y / max(size.x, 1)
        let sideShare = sideFlux / (1 + sideFlux)
        let target = configuration.targetDropCount
        let speeds = configuration.intensity.speedRange
        let meanSpeed = (speeds.lowerBound + speeds.upperBound) * 0.5
        let rate = Float(target) * meanSpeed / (size.y + 80) * (1 + sideFlux)
        spawnAccumulator = min(spawnAccumulator + rate * dt, 400)
        while spawnAccumulator >= 1 {
            spawnAccumulator -= 1
            guard liveRainCount < target else {
                spawnAccumulator = 0
                break
            }
            let position = random.unit() < sideShare ? sideEntry(slope: slope) : topEntry()
            drops.append(makeRainDrop(at: position))
            liveRainCount += 1
        }
    }

    private func topEntry() -> SIMD2<Float> {
        SIMD2(random.value(in: -20...(size.x + 20)), size.y + random.value(in: 8...90))
    }

    private func sideEntry(slope: Float) -> SIMD2<Float> {
        let inset = random.value(in: 10...60)
        let x = slope > 0 ? -inset : size.x + inset
        return SIMD2(x, random.value(in: 0...size.y))
    }

    private func makeRainDrop(at position: SIMD2<Float>) -> FallingDrop {
        let intensity = configuration.intensity
        let speed = random.value(in: intensity.speedRange)
        let angle = wind(atX: position.x).angle + random.value(in: -0.035...0.035)
        let velocity = SIMD2<Float>(sin(angle), -cos(angle)) * speed
        return FallingDrop(
            position: position,
            velocity: velocity,
            terminalSpeed: speed,
            gravity: 0,
            width: random.value(in: intensity.widthRange),
            streak: intensity.streakDuration * random.value(in: 0.8...1.25),
            alpha: random.value(in: 0.3...0.55),
            volume: 1,
            ignoredWindowID: 0,
            layerOrder: .max,
            isRain: true
        )
    }

    private func updateDrops(dt: Float) {
        liveRainCount = 0
        var index = 0
        while index < drops.count {
            var drop = drops[index]
            let previous = drop.position
            advance(&drop, dt: dt)
            if resolveImpact(of: drop, from: previous) {
                removeDrop(at: index)
                continue
            }
            drops[index] = drop
            if drop.isRain { liveRainCount += 1 }
            index += 1
        }
    }

    private func advance(_ drop: inout FallingDrop, dt: Float) {
        if drop.gravity > 0 {
            drop.velocity.y = max(drop.velocity.y - drop.gravity * dt, -drop.terminalSpeed)
        }
        if windStrength > 0.001 || drop.velocity.x != 0 {
            applyWind(to: &drop, dt: dt)
        }
        if let cursor = activeCursor {
            CursorInfluence.deflect(&drop, around: cursor, dt: dt)
        }
        drop.position += drop.velocity * dt
    }

    private func applyWind(to drop: inout FallingDrop, dt: Float) {
        let local = wind(atX: drop.position.x)
        let fallSpeed = max(-drop.velocity.y, 0)
        if drop.isRain {
            let target = tan(local.angle) * fallSpeed
            let response = 2.5 + 5 * local.gust
            drop.velocity.x += (target - drop.velocity.x) * min(dt * response, 1)
        } else {
            let target = tan(local.angle) * fallSpeed * 0.55
            drop.velocity.x += (target - drop.velocity.x) * min(dt * (0.8 + 1.5 * local.gust), 1)
        }
    }

    private func resolveImpact(of drop: FallingDrop, from previous: SIMD2<Float>) -> Bool {
        if let hit = scene.firstCrossing(from: previous, to: drop.position, ignoring: drop.ignoredWindowID) {
            impactOnWindow(drop, hit: hit)
            return true
        }
        if pool.isEnabled, drop.position.x >= 0, drop.position.x <= size.x {
            let surface = pool.surfaceHeight(atX: drop.position.x)
            if drop.position.y <= surface {
                impactOnPool(drop, surfaceY: surface)
                return true
            }
        }
        if scene.containsPoint(drop.position, ignoring: drop.ignoredWindowID, inFrontOf: drop.layerOrder) {
            return true
        }
        return isOutOfBounds(drop)
    }

    private func impactOnPool(_ drop: FallingDrop, surfaceY: Float) {
        let speed = simd_length(drop.velocity)
        let impulse = drop.isRain ? speed * 0.018 : speed * 0.03 * drop.volume.squareRoot()
        let radius: Float = drop.isRain ? 5 : 10
        pool.receive(volume: drop.volume, atX: drop.position.x, impulse: impulse, radius: radius)
        guard drop.position.x >= 0, drop.position.x <= size.x else { return }
        let count = drop.isRain ? random.integer(in: 1...2) : random.integer(in: 2...4)
        spawnSplashes(at: SIMD2(drop.position.x, surfaceY), incoming: drop.velocity, count: count, strength: impactStrength(of: drop) * 0.7)
    }

    private func impactOnWindow(_ drop: FallingDrop, hit: EdgeHit) {
        let strength = impactStrength(of: drop)
        let retained = drop.isRain ? drop.volume * 0.45 : drop.volume * 0.7
        puddles.deposit(windowID: hit.windowID, atX: hit.point.x, volume: retained)
        spawnSplashes(at: hit.point, incoming: drop.velocity, count: random.integer(in: 2...4), strength: strength)
    }

    private func impactStrength(of drop: FallingDrop) -> Float {
        let speedFactor = (simd_length(drop.velocity) / 1200).clamped(to: 0.35...1.2)
        return speedFactor * configuration.intensity.splashStrength
    }

    private func isOutOfBounds(_ drop: FallingDrop) -> Bool {
        let margin: Float = 120
        return drop.position.y < -40 || drop.position.x < -margin || drop.position.x > size.x + margin
    }

    private func removeDrop(at index: Int) {
        drops[index] = drops[drops.count - 1]
        drops.removeLast()
    }

    private func spawnSplashes(at point: SIMD2<Float>, incoming: SIMD2<Float>, count: Int, strength: Float) {
        for _ in 0..<count {
            guard splashes.count < configuration.splashCapacity else { return }
            let horizontal = random.signedUnit() * 120 * strength + incoming.x * 0.15
            let vertical = random.value(in: 0.35...1) * 210 * strength
            splashes.append(SplashParticle(
                position: point + SIMD2(0, 0.6),
                velocity: SIMD2(horizontal, vertical),
                age: 0,
                lifetime: random.value(in: 0.18...0.42),
                width: random.value(in: 0.7...1.25)
            ))
        }
    }

    private func updateSplashes(dt: Float) {
        var index = 0
        while index < splashes.count {
            splashes[index].age += dt
            if splashes[index].age >= splashes[index].lifetime {
                splashes[index] = splashes[splashes.count - 1]
                splashes.removeLast()
                continue
            }
            splashes[index].velocity.y -= splashGravity * dt
            splashes[index].velocity.x += splashPush[windColumn(atX: splashes[index].position.x)] * dt
            splashes[index].position += splashes[index].velocity * dt
            index += 1
        }
    }

    private func renderDrops(into segments: inout SegmentWriter) {
        let boost = lightBoost
        for drop in drops {
            let color = Palette.tinted(drop.isRain ? Palette.rain : Palette.drip, alpha: min(drop.alpha * boost, 1))
            segments.append(
                from: drop.tail,
                to: drop.position,
                width: drop.width,
                color: color,
                softness: 0.35,
                tailFade: drop.isRain ? 0.9 : 0.5
            )
        }
    }

    private func renderSplashes(into segments: inout SegmentWriter) {
        for splash in splashes {
            let alpha = 0.6 * splash.remainingFraction
            segments.append(
                from: splash.position - splash.velocity * 0.018,
                to: splash.position,
                width: splash.width,
                color: Palette.tinted(Palette.splash, alpha: alpha),
                softness: 0.4,
                tailFade: 0.7
            )
        }
    }
}
