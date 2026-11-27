import Foundation

struct OnePoleLowpass {
    private var state: Float = 0
    private var coefficient: Float = 1

    mutating func setCutoff(_ frequency: Float, sampleRate: Float) {
        coefficient = 1 - exp(-2 * Float.pi * frequency / sampleRate)
    }

    mutating func process(_ input: Float) -> Float {
        state += coefficient * (input - state)
        return state
    }
}

struct OnePoleHighpass {
    private var lowpass = OnePoleLowpass()

    mutating func setCutoff(_ frequency: Float, sampleRate: Float) {
        lowpass.setCutoff(frequency, sampleRate: sampleRate)
    }

    mutating func process(_ input: Float) -> Float {
        input - lowpass.process(input)
    }
}

struct PinkNoise {
    private var b0: Float = 0
    private var b1: Float = 0
    private var b2: Float = 0
    private var b3: Float = 0
    private var b4: Float = 0
    private var b5: Float = 0
    private var b6: Float = 0

    mutating func process(_ white: Float) -> Float {
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
        b6 = white * 0.115926
        return pink * 0.11
    }
}

struct SmoothedValue {
    private(set) var current: Float
    var target: Float
    private let rate: Float

    init(_ value: Float, smoothingSeconds: Float, sampleRate: Float) {
        current = value
        target = value
        rate = 1 / max(smoothingSeconds * sampleRate, 1)
    }

    mutating func next() -> Float {
        current += (target - current) * rate
        return current
    }
}

struct StateVariableBandpass {
    private var g: Float = 0
    private var k: Float = 1
    private var a1: Float = 0
    private var a2: Float = 0
    private var a3: Float = 0
    private var ic1: Float = 0
    private var ic2: Float = 0

    mutating func set(center: Float, quality: Float, sampleRate: Float) {
        let limited = min(center, sampleRate * 0.45)
        g = tan(Float.pi * limited / sampleRate)
        k = 1 / max(quality, 0.1)
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    mutating func process(_ input: Float) -> Float {
        let v3 = input - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return v1 * k
    }
}
