import Foundation

struct WindSample {
    var angle: Float
    var gust: Float
    var direction: Float

    static let calm = WindSample(angle: 0, gust: 0, direction: 0)
}

struct WindSchedule: Equatable {
    static let response = 1.2

    let startTime: Double
    let startStrength: Float
    let targetStrength: Float
    let startTempoPhase: Double
    let startGustPhase: Double

    static func steady(strength: Float) -> WindSchedule {
        WindSchedule(startTime: 0, startStrength: strength, targetStrength: strength, startTempoPhase: 0, startGustPhase: 0)
    }

    func strength(at time: Double) -> Float {
        let elapsed = max(time - startTime, 0)
        return targetStrength + (startStrength - targetStrength) * Float(exp(-Self.response * elapsed))
    }

    func phases(at time: Double) -> (tempo: Double, gust: Double) {
        let elapsed = time - startTime
        let decay = elapsed > 0 ? (1 - exp(-Self.response * elapsed)) / Self.response : elapsed
        let integral = Double(targetStrength) * elapsed + Double(startStrength - targetStrength) * decay
        return (startTempoPhase + 0.5 * elapsed + 1.5 * integral, startGustPhase + 0.3 * elapsed + 0.55 * integral)
    }

    func retargeted(to strength: Float, at time: Double) -> WindSchedule {
        guard strength != targetStrength else { return self }
        let current = phases(at: time)
        return WindSchedule(startTime: time, startStrength: self.strength(at: time), targetStrength: strength, startTempoPhase: current.tempo, startGustPhase: current.gust)
    }
}

struct WindField {
    static let maximumAngle: Float = 0.78

    var schedule: WindSchedule
    var level: Float = 1
    var bias: Float = 0

    init(schedule: WindSchedule, level: Float = 1, bias: Float = 0) {
        self.schedule = schedule
        self.level = level
        self.bias = bias
    }

    init(strength: Float, bias: Float = 0) {
        self.init(schedule: .steady(strength: strength), bias: bias)
    }

    func strength(at time: Double) -> Float {
        schedule.strength(at: time) * level
    }

    func sample(at time: Double, x: Float = 0) -> WindSample {
        let base = schedule.strength(at: time)
        let s = base * level
        guard s > 0.001 else { return .calm }
        let phase = schedule.phases(at: time)
        let centerDirection = direction(tempoPhase: phase.tempo, strength: s)
        let travel = Double(1300 + 1700 * s)
        let shift = Double(x * centerDirection) / travel
        let tempoPhase = phase.tempo - shift * Double(0.5 + 1.5 * base)
        let gustPhase = phase.gust - shift * Double(0.3 + 0.55 * base)
        let localDirection = direction(tempoPhase: tempoPhase, strength: s)
        let surge = gustSurge(phase: gustPhase)
        let flutter = ValueNoise.fractal((time - shift) * 2.4, seed: 53, octaves: 2) * 0.07 * s
        let angle = Self.maximumAngle * s * localDirection * (0.35 + 0.65 * surge) + flutter
        return WindSample(angle: angle, gust: s * (0.3 + 0.7 * surge), direction: localDirection)
    }

    private func direction(tempoPhase: Double, strength s: Float) -> Float {
        let prevailing = ValueNoise.fractal(tempoPhase * 0.04, seed: 11, octaves: 2)
        let swing = ValueNoise.fractal(tempoPhase * 0.3, seed: 23, octaves: 2)
        let sharpness = 1.4 + 3.2 * s
        let shifting = tanh((prevailing * 1.3 + swing * (0.35 + 0.9 * s)) * sharpness)
        guard abs(bias) > 0.001 else { return shifting }
        let steady = (bias > 0 ? 1 : -1) * (0.7 + 0.3 * abs(shifting))
        return shifting + (steady - shifting) * min(abs(bias), 1)
    }

    private func gustSurge(phase: Double) -> Float {
        let noise = 0.5 + 0.5 * ValueNoise.fractal(phase, seed: 37, octaves: 3)
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
