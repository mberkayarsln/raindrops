import simd

struct FallingDrop {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var terminalSpeed: Float
    var gravity: Float
    var width: Float
    var streak: Float
    var alpha: Float
    var volume: Float
    var ignoredWindowID: UInt32
    var layerOrder: Int
    var isRain: Bool

    var tail: SIMD2<Float> {
        let trail = velocity * streak
        let minimumLength = width * 1.2
        let trailLength = simd_length(trail)
        guard trailLength < minimumLength else { return position - trail }
        let direction = trailLength > 0.001 ? trail / trailLength : SIMD2<Float>(0, -1)
        return position - direction * minimumLength
    }
}

struct SplashParticle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var age: Float
    var lifetime: Float
    var width: Float

    var remainingFraction: Float {
        max(0, 1 - age / lifetime)
    }
}

enum Palette {
    static let rain = SIMD4<Float>(0.80, 0.87, 0.97, 1)
    static let drip = SIMD4<Float>(0.84, 0.91, 1.0, 1)
    static let splash = SIMD4<Float>(0.88, 0.93, 1.0, 1)
    static let stream = SIMD4<Float>(0.70, 0.82, 0.96, 1)
    static let streamHighlight = SIMD4<Float>(0.95, 0.98, 1.0, 1)

    static func tinted(_ color: SIMD4<Float>, alpha: Float) -> SIMD4<Float> {
        SIMD4(color.x, color.y, color.z, alpha)
    }
}
