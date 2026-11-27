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

    func step(dt: Float, windows: [WindowRecord], screenOrigin: SIMD2<Float>, cursor: CursorSample?) {
        time += dt
        activeCursor = configuration.isCursorInteractionEnabled ? cursor : nil
        scene.rebuild(from: windows, screenOrigin: screenOrigin, screenSize: size)
        puddles.synchronize(with: scene)
        collectEmittedDrops()
        spawnRain(dt: dt)
        updateDrops(dt: dt)
        updateSplashes(dt: dt)
        puddles.step(dt: dt, scene: scene, floorHeight: pool.surfaceHeight(atX:))
        collectEmittedDrops()
        stirPool(dt: dt)
        pool.step(dt: dt)
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
        pool.render(into: &water)
        puddles.renderWater(into: &water, scene: scene)
        puddles.renderStreams(into: &segments, scene: scene, time: time)
        renderDrops(into: &segments)
        renderSplashes(into: &segments)
    }

    private var windDirection: SIMD2<Float> {
        SIMD2(sin(configuration.windAngle), -cos(configuration.windAngle))
    }

    private func spawnRain(dt: Float) {
        let target = configuration.targetDropCount
        let speeds = configuration.intensity.speedRange
        let meanSpeed = (speeds.lowerBound + speeds.upperBound) * 0.5
        let rate = Float(target) * meanSpeed / (size.y + 80)
        spawnAccumulator = min(spawnAccumulator + rate * dt, 400)
        while spawnAccumulator >= 1 {
            spawnAccumulator -= 1
            guard liveRainCount < target else {
                spawnAccumulator = 0
                break
            }
            drops.append(makeRainDrop())
            liveRainCount += 1
        }
    }

    private func makeRainDrop() -> FallingDrop {
        let intensity = configuration.intensity
        let speed = random.value(in: intensity.speedRange)
        let angle = configuration.windAngle + random.value(in: -0.035...0.035)
        let velocity = SIMD2<Float>(sin(angle), -cos(angle)) * speed
        let drift = tan(configuration.windAngle) * size.y
        let minimumX = min(0, -drift) - 30
        let maximumX = max(size.x, size.x - drift) + 30
        let position = SIMD2<Float>(random.value(in: minimumX...maximumX), size.y + random.value(in: 8...90))
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
        if drop.isRain {
            let targetHorizontal = windDirection.x * drop.terminalSpeed
            drop.velocity.x += (targetHorizontal - drop.velocity.x) * min(dt * 1.5, 1)
        }
        if let cursor = activeCursor {
            CursorInfluence.deflect(&drop, around: cursor, dt: dt)
        }
        drop.position += drop.velocity * dt
    }

    private func resolveImpact(of drop: FallingDrop, from previous: SIMD2<Float>) -> Bool {
        if let hit = scene.firstCrossing(from: previous, to: drop.position, ignoring: drop.ignoredWindowID) {
            impactOnWindow(drop, hit: hit)
            return true
        }
        if scene.containsPoint(drop.position, ignoring: drop.ignoredWindowID, inFrontOf: drop.layerOrder) {
            return true
        }
        if pool.isEnabled {
            let surface = pool.surfaceHeight(atX: drop.position.x)
            if drop.position.y <= surface {
                impactOnPool(drop, surfaceY: surface)
                return true
            }
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
        drop.position.y < -40 || drop.position.x < -400 || drop.position.x > size.x + 400
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
            splashes[index].position += splashes[index].velocity * dt
            index += 1
        }
    }

    private func renderDrops(into segments: inout SegmentWriter) {
        for drop in drops {
            let color = Palette.tinted(drop.isRain ? Palette.rain : Palette.drip, alpha: drop.alpha)
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
