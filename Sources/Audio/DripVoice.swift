import Foundation

struct DripVoice {
    private struct Bubble {
        var delay = 0
        var phase: Float = 0
        var frequency: Float = 0
        var rise: Float = 0
        var amplitude: Float = 0
        var decay: Float = 0
        var attack: Float = 0
        var attackStep: Float = 0

        var isActive: Bool {
            amplitude > 0.0003
        }

        mutating func start(delay: Int, frequency: Float, riseRate: Float, amplitude: Float, decaySeconds: Float, sampleRate: Float) {
            self.delay = delay
            self.frequency = frequency
            rise = frequency * riseRate / sampleRate
            self.amplitude = amplitude
            decay = exp(-1 / (decaySeconds * sampleRate))
            phase = 0
            attack = 0
            attackStep = 1 / (0.001 * sampleRate)
        }

        mutating func sample(sampleDuration: Float) -> Float {
            guard isActive else { return 0 }
            if delay > 0 {
                delay -= 1
                return 0
            }
            frequency += rise
            phase += frequency * sampleDuration
            if phase >= 1 { phase -= 1 }
            attack = min(attack + attackStep, 1)
            let value = sin(phase * 2 * .pi) * amplitude * attack
            amplitude *= decay
            return value
        }
    }

    private(set) var isActive = false
    private var main = Bubble()
    private var echo = Bubble()
    private var impact: Float = 0
    private var impactDecay: Float = 0
    private var thump: Float = 0
    private var thumpDecay: Float = 0
    private var impactHighpass = OnePoleHighpass()
    private var impactLowpass = OnePoleLowpass()
    private var thumpFilter = OnePoleLowpass()
    private var toneFilter = OnePoleLowpass()
    private var sampleDuration: Float = 0
    private var gains = SIMD2<Float>(repeating: 0)

    mutating func start(strength: Float, sampleRate: Float, random: inout FastRandom) {
        sampleDuration = 1 / sampleRate
        let frequency = random.value(in: 560...780)
        let riseRate = random.value(in: 12...22)
        let level = random.value(in: 0.22...0.27) * strength
        main.start(
            delay: Int(random.value(in: 0.0015...0.0035) * sampleRate),
            frequency: frequency,
            riseRate: riseRate,
            amplitude: level,
            decaySeconds: random.value(in: 0.02...0.03),
            sampleRate: sampleRate
        )
        if random.unit() < 0.45 {
            echo.start(
                delay: Int(random.value(in: 0.006...0.014) * sampleRate),
                frequency: frequency * random.value(in: 1.35...1.8),
                riseRate: riseRate,
                amplitude: level * random.value(in: 0.35...0.5),
                decaySeconds: random.value(in: 0.012...0.018),
                sampleRate: sampleRate
            )
        } else {
            echo = Bubble()
        }
        impact = 0.5 * strength
        impactDecay = exp(-1 / (0.0012 * sampleRate))
        thump = 0.6 * strength
        thumpDecay = exp(-1 / (0.005 * sampleRate))
        impactHighpass.setCutoff(700, sampleRate: sampleRate)
        impactLowpass.setCutoff(2200, sampleRate: sampleRate)
        thumpFilter.setCutoff(400, sampleRate: sampleRate)
        toneFilter.setCutoff(2400, sampleRate: sampleRate)
        let pan = random.value(in: 0.25...0.75)
        gains = SIMD2(cos(pan * .pi * 0.5), sin(pan * .pi * 0.5)) * 1.2
        isActive = true
    }

    mutating func sample(noise: Float) -> SIMD2<Float> {
        guard isActive else { return .zero }
        let ring = main.sample(sampleDuration: sampleDuration) + echo.sample(sampleDuration: sampleDuration)
        let tap = impactLowpass.process(impactHighpass.process(noise)) * impact
        let body = thumpFilter.process(noise) * thump
        let value = toneFilter.process(ring + tap + body)
        impact *= impactDecay
        thump *= thumpDecay
        if !main.isActive, !echo.isActive, thump < 0.0003 { isActive = false }
        return gains * value
    }
}
