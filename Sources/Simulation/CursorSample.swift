import simd

struct CursorSample {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
}

struct CursorInfluence {
    static let deflectionRadius: Float = 64
    static let deflectionAcceleration: Float = 2600

    private var wasInWater = false

    static func deflect(_ drop: inout FallingDrop, around cursor: CursorSample, dt: Float) {
        let offset = drop.position - cursor.position
        let distanceSquared = simd_length_squared(offset)
        guard distanceSquared < deflectionRadius * deflectionRadius else { return }
        let falloff = 1 - distanceSquared.squareRoot() / deflectionRadius
        let direction: Float = offset.x >= 0 ? 1 : -1
        drop.velocity.x += direction * falloff * deflectionAcceleration * dt
    }

    mutating func stir(_ pool: BottomPool, with cursor: CursorSample?, dt: Float) -> SIMD2<Float>? {
        guard let cursor, pool.isVisible else {
            wasInWater = false
            return nil
        }
        let surface = pool.surfaceHeight(atX: cursor.position.x)
        let inWater = cursor.position.y <= surface + 2
        defer { wasInWater = inWater }
        guard inWater else { return nil }
        if !wasInWater {
            let entrySpeed = min(abs(cursor.velocity.y) + abs(cursor.velocity.x) * 0.3, 1800)
            pool.disturb(atX: cursor.position.x, strength: 70 + entrySpeed * 0.09, radius: 10)
            return SIMD2(cursor.position.x, surface)
        }
        let speed = min(simd_length(cursor.velocity), 2500)
        guard speed > 15 else { return nil }
        let depthRatio = ((surface - cursor.position.y) / max(surface, 1)).clamped(to: 0...1)
        pool.disturb(atX: cursor.position.x, strength: speed * 1.6 * dt * (1 - depthRatio * 0.6), radius: 8)
        return nil
    }
}
