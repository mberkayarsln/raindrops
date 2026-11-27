import Foundation

struct ThunderVoice {
    private static let maximumPeals = 8

    private(set) var isActive = false
    private var sampleRate: Float = 48_000
    private var age: Float = 0
    private var duration: Float = 6
    private var loudness: Float = 1
    private var crack: Float = 0
    private var brightness: Float = 1000
    private var pealTimes = SIMD8<Float>(repeating: .infinity)
    private var pealAttacks = SIMD8<Float>(repeating: 0.1)
    private var pealDecays = SIMD8<Float>(repeating: 1)
    private var pealGains = SIMD8<Float>.zero
    private var pealLevels = SIMD8<Float>.zero
    private var envelopeSmoother = OnePoleLowpass()
    private var swell = OnePoleLowpass()
    private var swellTarget: Float = 1
    private var swellTimer: Float = 0
    private var controlCountdown = 0
    private var brown: Float = 0
    private var subFirst = OnePoleLowpass()
    private var subSecond = OnePoleLowpass()
    private var harmonicHighpass = OnePoleHighpass()
    private var bodyLeft = BandNoise()
    private var bodyRight = BandNoise()
    private var crackHighpass = OnePoleHighpass()
    private var crackSmoother = OnePoleLowpass()

    mutating func start(distance: Float, sampleRate: Float, random: inout FastRandom) {
        self.sampleRate = sampleRate
        isActive = true
        age = 0
        duration = 5 + distance * 5 + random.value(in: 0...2.5)
        loudness = 1 - distance * 0.4
        crack = max(0.35 - distance, 0) / 0.35
        brightness = 1600 - distance * 900
        schedulePeals(distance: distance, random: &random)
        envelopeSmoother.setCutoff(30, sampleRate: sampleRate)
        swell.setCutoff(2.5, sampleRate: sampleRate)
        subFirst.setCutoff(110, sampleRate: sampleRate)
        subSecond.setCutoff(110, sampleRate: sampleRate)
        harmonicHighpass.setCutoff(160, sampleRate: sampleRate)
        bodyLeft.configure(highpass: 80, lowpass: brightness, sampleRate: sampleRate)
        bodyRight.configure(highpass: 80, lowpass: brightness, sampleRate: sampleRate)
        crackHighpass.setCutoff(600, sampleRate: sampleRate)
        crackSmoother.setCutoff(200, sampleRate: sampleRate)
        swellTarget = 1
        swellTimer = 0
        controlCountdown = 0
    }

    mutating func sample(whiteLeft: Float, whiteRight: Float, random: inout FastRandom) -> SIMD2<Float> {
        guard isActive else { return .zero }
        let dt = 1 / sampleRate
        age += dt
        updateControls(random: &random)
        let level = envelopeSmoother.process(pealEnvelope(dt: dt)) * swell.process(swellTarget) * loudness
        guard age < duration || level > 0.0005 else {
            isActive = false
            return .zero
        }
        let sub = subRumble(white: (whiteLeft + whiteRight) * 0.5)
        let body = SIMD2(bodyLeft.process(whiteLeft), bodyRight.process(whiteRight)) * 6
        let crackSignal = crackHighpass.process(whiteLeft) * crackEnvelope(random: &random)
        return (body + SIMD2(repeating: sub)) * level + SIMD2(repeating: crackSignal)
    }

    private mutating func schedulePeals(distance: Float, random: inout FastRandom) {
        let count = random.integer(in: 5...Self.maximumPeals)
        let spread = duration * (0.35 + distance * 0.2)
        let onset = distance * 0.4
        for index in 0..<Self.maximumPeals {
            guard index < count else {
                pealTimes[index] = .infinity
                pealGains[index] = 0
                continue
            }
            let isFirst = index == 0
            pealTimes[index] = isFirst ? 0 : onset + random.value(in: 0...spread)
            pealAttacks[index] = isFirst ? 0.02 + distance * 0.35 : random.value(in: 0.12...0.45)
            pealDecays[index] = random.value(in: 0.9...2.2) * (1 + distance)
            pealGains[index] = isFirst ? 1 : random.value(in: 0.35...0.9)
        }
        pealLevels = .zero
    }

    private mutating func pealEnvelope(dt: Float) -> Float {
        var total: Float = 0
        for index in 0..<Self.maximumPeals {
            let elapsed = age - pealTimes[index]
            guard elapsed > 0 else { continue }
            let attack = pealAttacks[index]
            if elapsed < attack {
                let progress = elapsed / attack
                pealLevels[index] = pealGains[index] * progress * progress * (3 - 2 * progress)
            } else {
                pealLevels[index] *= 1 - dt / pealDecays[index]
            }
            total += pealLevels[index]
        }
        return min(total, 1.2)
    }

    private mutating func updateControls(random: inout FastRandom) {
        controlCountdown -= 1
        guard controlCountdown <= 0 else { return }
        controlCountdown = 64
        let controlStep = 64 / sampleRate
        swellTimer -= controlStep
        if swellTimer <= 0 {
            swellTarget = random.value(in: 0.7...1)
            swellTimer = random.value(in: 0.25...0.7)
        }
        let darkening = 0.55 + 0.45 * exp(-age * 0.6)
        bodyLeft.setLowpass(brightness * darkening, sampleRate: sampleRate)
        bodyRight.setLowpass(brightness * darkening, sampleRate: sampleRate)
    }

    private mutating func subRumble(white: Float) -> Float {
        brown = (brown + white * 0.02) * 0.998
        let sub = subSecond.process(subFirst.process(brown)) * 3.2
        return sub + harmonicHighpass.process(tanh(sub * 3)) * 0.3
    }

    private mutating func crackEnvelope(random: inout FastRandom) -> Float {
        guard crack > 0, age < 0.6 else { return 0 }
        let grain: Float = random.unit() < 0.004 ? random.value(in: 0.3...1) : 0
        let flicker = crackSmoother.process(grain * 40)
        return crack * loudness * exp(-age * 7) * (0.35 + flicker)
    }
}

struct BandNoise {
    private var highpass = OnePoleHighpass()
    private var first = OnePoleLowpass()
    private var second = OnePoleLowpass()

    mutating func configure(highpass cutoff: Float, lowpass: Float, sampleRate: Float) {
        highpass.setCutoff(cutoff, sampleRate: sampleRate)
        setLowpass(lowpass, sampleRate: sampleRate)
    }

    mutating func setLowpass(_ cutoff: Float, sampleRate: Float) {
        first.setCutoff(cutoff, sampleRate: sampleRate)
        second.setCutoff(cutoff, sampleRate: sampleRate)
    }

    mutating func process(_ input: Float) -> Float {
        second.process(first.process(highpass.process(input)))
    }
}
