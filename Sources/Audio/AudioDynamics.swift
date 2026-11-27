import Foundation

final class StereoReverb {
    private let combsLeft: [DelayLine]
    private let combsRight: [DelayLine]
    private let allpassesLeft: [DelayLine]
    private let allpassesRight: [DelayLine]
    private let feedback: Float = 0.84
    private let damping: Float = 0.35

    init(sampleRate: Float) {
        let scale = sampleRate / 44_100
        let combLengths = [1116, 1188, 1277, 1356]
        let allpassLengths = [556, 441]
        let spread = 23
        combsLeft = combLengths.map { DelayLine(length: Int(Float($0) * scale)) }
        combsRight = combLengths.map { DelayLine(length: Int(Float($0 + spread) * scale)) }
        allpassesLeft = allpassLengths.map { DelayLine(length: Int(Float($0) * scale)) }
        allpassesRight = allpassLengths.map { DelayLine(length: Int(Float($0 + spread) * scale)) }
    }

    func process(_ input: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(
            channel(input.x, combs: combsLeft, allpasses: allpassesLeft),
            channel(input.y, combs: combsRight, allpasses: allpassesRight)
        )
    }

    private func channel(_ input: Float, combs: [DelayLine], allpasses: [DelayLine]) -> Float {
        var sum: Float = 0
        for comb in combs {
            sum += comb.comb(input * 0.12, feedback: feedback, damping: damping)
        }
        for allpass in allpasses {
            sum = allpass.allpass(sum)
        }
        return sum
    }
}

final class DelayLine {
    private let buffer: UnsafeMutablePointer<Float>
    private let length: Int
    private var index = 0
    private var filterState: Float = 0

    init(length: Int) {
        self.length = max(length, 1)
        buffer = .allocate(capacity: self.length)
        buffer.initialize(repeating: 0, count: self.length)
    }

    deinit {
        buffer.deallocate()
    }

    func comb(_ input: Float, feedback: Float, damping: Float) -> Float {
        let output = buffer[index]
        filterState = output * (1 - damping) + filterState * damping
        buffer[index] = input + filterState * feedback
        advance()
        return output
    }

    func allpass(_ input: Float) -> Float {
        let delayed = buffer[index]
        buffer[index] = input + delayed * 0.5
        advance()
        return delayed - input
    }

    private func advance() {
        index += 1
        if index >= length { index = 0 }
    }
}

struct SoftLimiter {
    private var gain: Float = 1
    private let ceiling: Float = 0.85
    private let attack: Float
    private let release: Float

    init(sampleRate: Float) {
        attack = 1 - exp(-1 / (0.002 * sampleRate))
        release = 1 - exp(-1 / (0.35 * sampleRate))
    }

    mutating func process(_ input: SIMD2<Float>) -> SIMD2<Float> {
        let peak = max(abs(input.x), abs(input.y))
        let target = peak > ceiling ? ceiling / peak : 1
        gain += (target - gain) * (target < gain ? attack : release)
        let output = input * gain
        return SIMD2(Self.safety(output.x), Self.safety(output.y))
    }

    private static func safety(_ value: Float) -> Float {
        abs(value) < 0.9 ? value : tanh(value)
    }
}
