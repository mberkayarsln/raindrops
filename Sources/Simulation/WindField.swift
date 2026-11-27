import Foundation

struct WindSample {
    var angle: Float
    var gust: Float
    var direction: Float

    static let calm = WindSample(angle: 0, gust: 0, direction: 0)
}

struct WindField {
    static let maximumAngle: Float = 0.78

    var strength: Float

    func sample(at time: Double, x: Float = 0) -> WindSample {
        let s = strength
        guard s > 0.001 else { return .calm }
        let tempo = Double(0.5 + 1.5 * s)
        let centerDirection = direction(at: time, tempo: tempo, strength: s)
        let travel = Double(1300 + 1700 * s)
        let localTime = time - Double(x * centerDirection) / travel
        let localDirection = direction(at: localTime, tempo: tempo, strength: s)
        let surge = gustSurge(at: localTime, strength: s)
        let flutter = ValueNoise.fractal(localTime * 2.4, seed: 53, octaves: 2) * 0.07 * s
        let angle = Self.maximumAngle * s * localDirection * (0.35 + 0.65 * surge) + flutter
        return WindSample(angle: angle, gust: s * (0.3 + 0.7 * surge), direction: localDirection)
    }

    private func direction(at time: Double, tempo: Double, strength s: Float) -> Float {
        let prevailing = ValueNoise.fractal(time * 0.04 * tempo, seed: 11, octaves: 2)
        let swing = ValueNoise.fractal(time * 0.3 * tempo, seed: 23, octaves: 2)
        let sharpness = 1.4 + 3.2 * s
        return tanh((prevailing * 1.3 + swing * (0.35 + 0.9 * s)) * sharpness)
    }

    private func gustSurge(at time: Double, strength s: Float) -> Float {
        let noise = 0.5 + 0.5 * ValueNoise.fractal(time * Double(0.3 + 0.55 * s), seed: 37, octaves: 3)
        return pow(min(max(noise, 0), 1), 1.6)
    }
}

enum ValueNoise {
    static func fractal(_ x: Double, seed: UInt32, octaves: Int) -> Float {
        var total: Float = 0
        var amplitude: Float = 1
        var frequency = 1.0
        var normalization: Float = 0
        for octave in 0..<octaves {
            total += value(x * frequency, seed: seed &+ UInt32(octave) &* 101) * amplitude
            normalization += amplitude
            amplitude *= 0.5
            frequency *= 2.03
        }
        return total / normalization * 1.35
    }

    static func value(_ x: Double, seed: UInt32) -> Float {
        let cell = x.rounded(.down)
        let fraction = Float(x - cell)
        let index = Int64(cell)
        let a = lattice(index, seed: seed)
        let b = lattice(index &+ 1, seed: seed)
        let eased = fraction * fraction * fraction * (fraction * (fraction * 6 - 15) + 10)
        return a + (b - a) * eased
    }

    private static func lattice(_ index: Int64, seed: UInt32) -> Float {
        var hash = UInt64(bitPattern: index) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(seed) &* 0xBF58_476D_1CE4_E5B9
        hash ^= hash >> 31
        hash &*= 0x94D0_49BB_1331_11EB
        hash ^= hash >> 29
        return Float(hash >> 40) / Float(1 << 23) - 1
    }
}
