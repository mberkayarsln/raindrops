import Foundation

struct WindVoice {
    private let sampleRate: Float
    private var gust: Float = 0
    private var direction: Float = 0
    private var strength: Float = 0
    private var level = OnePoleLowpass()
    private var howlLevel = OnePoleLowpass()
    private var hissLevel = OnePoleLowpass()
    private var panSmoother = OnePoleLowpass()
    private var pinkLeft = PinkNoise()
    private var pinkRight = PinkNoise()
    private var whooshLeft = StateVariableBandpass()
    private var whooshRight = StateVariableBandpass()
    private var lowLeft = BandNoise()
    private var lowRight = BandNoise()
    private var hissLeft = OnePoleHighpass()
    private var hissRight = OnePoleHighpass()
    private var howlFirst = StateVariableBandpass()
    private var howlSecond = StateVariableBandpass()
    private var vibratoPhase: Double = 0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        level.setCutoff(18, sampleRate: sampleRate)
        howlLevel.setCutoff(6, sampleRate: sampleRate)
        hissLevel.setCutoff(12, sampleRate: sampleRate)
        panSmoother.setCutoff(3, sampleRate: sampleRate)
        lowLeft.configure(highpass: 70, lowpass: 320, sampleRate: sampleRate)
        lowRight.configure(highpass: 70, lowpass: 320, sampleRate: sampleRate)
        hissLeft.setCutoff(2600, sampleRate: sampleRate)
        hissRight.setCutoff(2900, sampleRate: sampleRate)
        update(with: .calm, strength: 0, time: 0)
    }

    var isAudible: Bool {
        strength > 0.003
    }

    mutating func update(with sample: WindSample, strength: Float, time: Double) {
        gust = sample.gust
        direction = sample.direction
        self.strength = strength
        let center = 230 + 1250 * pow(gust, 1.15)
        let quality = 0.75 + 0.9 * gust
        whooshLeft.set(center: center, quality: quality, sampleRate: sampleRate)
        whooshRight.set(center: center * 1.09, quality: quality, sampleRate: sampleRate)
        let vibrato = 1 + 0.025 * ValueNoise.fractal(time * 0.7, seed: 71, octaves: 2)
        let howlBase = (300 + 420 * gust) * vibrato
        howlFirst.set(center: howlBase, quality: 16, sampleRate: sampleRate)
        howlSecond.set(center: howlBase * 1.47, quality: 18, sampleRate: sampleRate)
    }

    mutating func sample(whiteLeft: Float, whiteRight: Float, whiteShared: Float) -> SIMD2<Float> {
        let amplitude = level.process(pow(gust, 1.1) * 1.9)
        let howl = howlLevel.process(Self.smoothstep((gust - 0.42) / 0.45) * strength)
        let hiss = hissLevel.process(max(gust - 0.35, 0) * 1.6)
        let pan = panSmoother.process(direction * (0.25 + 0.2 * gust))
        guard amplitude > 0.0004 || howl > 0.0004 else { return .zero }
        let noiseLeft = pinkLeft.process(whiteLeft)
        let noiseRight = pinkRight.process(whiteRight)
        let whistle = (howlFirst.process(whiteShared) + howlSecond.process(whiteShared) * 0.6) * howl * 2.2
        let left = whooshLeft.process(noiseLeft) * 1.5 + lowLeft.process(noiseLeft) * 2.4 + hissLeft.process(whiteLeft) * hiss * 0.12
        let right = whooshRight.process(noiseRight) * 1.5 + lowRight.process(noiseRight) * 2.4 + hissRight.process(whiteRight) * hiss * 0.12
        let gains = Self.equalPowerGains(pan: pan)
        return SIMD2(left * amplitude + whistle * 0.8, right * amplitude + whistle * 0.8) * gains
    }

    private static func equalPowerGains(pan: Float) -> SIMD2<Float> {
        let angle = (pan.clamped(to: -1...1) + 1) * Float.pi * 0.25
        return SIMD2(cos(angle), sin(angle)) * 1.41421356
    }

    private static func smoothstep(_ value: Float) -> Float {
        let x = value.clamped(to: 0...1)
        return x * x * (3 - 2 * x)
    }
}
