import Foundation
import QuartzCore

struct SoundProfile {
    let bedLevel: Float
    let patterRate: Float
    let brightness: Float
    var windSchedule = WindSchedule.steady(strength: 0)
    var windBias: Float = 0

    static let silent = SoundProfile(bedLevel: 0, patterRate: 0, brightness: 6000)

    init(bedLevel: Float, patterRate: Float, brightness: Float) {
        self.bedLevel = bedLevel
        self.patterRate = patterRate
        self.brightness = brightness
    }

    init(intensity: RainIntensity, windSchedule: WindSchedule = .steady(strength: 0), windDirection: WindDirection = .shifting) {
        switch intensity {
        case .drizzle: self.init(bedLevel: 0.28, patterRate: 30, brightness: 6000)
        case .rain: self.init(bedLevel: 0.55, patterRate: 110, brightness: 8000)
        case .downpour: self.init(bedLevel: 0.9, patterRate: 300, brightness: 11000)
        }
        self.windSchedule = windSchedule
        self.windBias = windDirection.bias
    }
}

final class RainSynth {
    private static let thunderVoiceCount = 3
    private static let dripVoiceCount = 2

    private let sampleRate: Float
    private let sampleDuration: Float
    private var random = FastRandom(seed: 0x5EED_F00D)
    private var bedLevel: SmoothedValue
    private var patterRate: SmoothedValue
    private var volume: SmoothedValue
    private var pinkLeft = PinkNoise()
    private var pinkRight = PinkNoise()
    private var bedHighpassLeft = OnePoleHighpass()
    private var bedHighpassRight = OnePoleHighpass()
    private var bedLowpassLeft = OnePoleLowpass()
    private var bedLowpassRight = OnePoleLowpass()
    private var tickHighpass = OnePoleHighpass()
    private var plopLowpass = OnePoleLowpass()
    private var tickEnvelope = SIMD2<Float>.zero
    private var plopEnvelope = SIMD2<Float>.zero
    private let tickDecay: Float
    private let plopDecay: Float
    private var thunderVoices: [ThunderVoice]
    private let reverb: StereoReverb
    private var windVoice: WindVoice
    private var windLevel: SmoothedValue
    private var windBias: SmoothedValue
    private var dripVoices: [DripVoice]
    private var windControlCountdown = 0
    private var gustSwell: Float = 0
    private var reverbTailSamples = 0
    private let reverbTailLength: Int
    private static let windControlInterval = 64
    private var limiter: SoftLimiter
    private var appliedBrightness: Float = 0
    private var seenThunderSequence = 0
    private var seenDripSequence = 0

    var profile = SoundProfile.silent
    var masterVolume: Float = 0.5
    var rainLevel: Float = 1
    private var requestedDripSequence = 0
    private var requestedDripStrength: Float = 1
    private var requestedThunderSequence = 0
    private var requestedThunderDistance: Float = 0.5

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        sampleDuration = 1 / sampleRate
        bedLevel = SmoothedValue(0, smoothingSeconds: 0.6, sampleRate: sampleRate)
        patterRate = SmoothedValue(0, smoothingSeconds: 0.6, sampleRate: sampleRate)
        volume = SmoothedValue(0, smoothingSeconds: 0.15, sampleRate: sampleRate)
        tickDecay = exp(-1 / (0.003 * sampleRate))
        plopDecay = exp(-1 / (0.011 * sampleRate))
        thunderVoices = Array(repeating: ThunderVoice(), count: Self.thunderVoiceCount)
        reverb = StereoReverb(sampleRate: sampleRate)
        reverbTailLength = Int(sampleRate * 6)
        windVoice = WindVoice(sampleRate: sampleRate)
        windLevel = SmoothedValue(0, smoothingSeconds: 0.7, sampleRate: sampleRate)
        windBias = SmoothedValue(0, smoothingSeconds: 1, sampleRate: sampleRate)
        dripVoices = Array(repeating: DripVoice(), count: Self.dripVoiceCount)
        limiter = SoftLimiter(sampleRate: sampleRate)
        bedHighpassLeft.setCutoff(320, sampleRate: sampleRate)
        bedHighpassRight.setCutoff(320, sampleRate: sampleRate)
        tickHighpass.setCutoff(2200, sampleRate: sampleRate)
        plopLowpass.setCutoff(1300, sampleRate: sampleRate)
    }

    func requestThunder(distance: Float) {
        requestedThunderDistance = distance
        requestedThunderSequence &+= 1
    }

    func requestDrip(strength: Float) {
        requestedDripStrength = strength
        requestedDripSequence &+= 1
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        render(left: left, right: right, frames: frames, startTime: CACurrentMediaTime())
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, startTime blockTime: Double) {
        applyParameters()
        for frame in 0..<frames {
            updateWindIfNeeded(at: blockTime + Double(frame) / Double(sampleRate))
            let output = nextSample()
            left[frame] = output.x
            right[frame] = output.y
        }
    }

    private func applyParameters() {
        let level = rainLevel.clamped(to: 0...1)
        bedLevel.target = profile.bedLevel * level
        patterRate.target = profile.patterRate * level
        volume.target = masterVolume
        windLevel.target = level
        windBias.target = profile.windBias
        if appliedBrightness != profile.brightness {
            appliedBrightness = profile.brightness
            bedLowpassLeft.setCutoff(profile.brightness, sampleRate: sampleRate)
            bedLowpassRight.setCutoff(profile.brightness, sampleRate: sampleRate)
        }
        if seenThunderSequence != requestedThunderSequence {
            seenThunderSequence = requestedThunderSequence
            startThunder(distance: requestedThunderDistance)
        }
        if seenDripSequence != requestedDripSequence {
            seenDripSequence = requestedDripSequence
            startDrip()
        }
    }

    private func updateWindIfNeeded(at time: Double) {
        let level = windLevel.next()
        let bias = windBias.next()
        windControlCountdown -= 1
        guard windControlCountdown <= 0 else { return }
        windControlCountdown = Self.windControlInterval
        let field = WindField(schedule: profile.windSchedule, level: level, bias: bias)
        let sample = field.sample(at: time)
        windVoice.update(with: sample, strength: field.strength(at: time), time: time)
        gustSwell = sample.gust
    }

    private func startThunder(distance: Float) {
        let index = thunderVoices.firstIndex { !$0.isActive } ?? Int(random.next() % UInt64(thunderVoices.count))
        thunderVoices[index].start(distance: distance, sampleRate: sampleRate, random: &random)
    }

    private func startDrip() {
        let index = dripVoices.firstIndex { !$0.isActive } ?? 0
        dripVoices[index].start(strength: requestedDripStrength, sampleRate: sampleRate, random: &random)
    }

    private func dripSample() -> SIMD2<Float> {
        var total = SIMD2<Float>.zero
        for index in dripVoices.indices where dripVoices[index].isActive {
            total += dripVoices[index].sample(noise: random.signedUnit())
        }
        return total
    }

    private func nextSample() -> SIMD2<Float> {
        triggerPatter()
        let whiteLeft = random.signedUnit()
        let whiteRight = random.signedUnit()
        let bed = SIMD2(
            bedLowpassLeft.process(bedHighpassLeft.process(pinkLeft.process(whiteLeft))),
            bedLowpassRight.process(bedHighpassRight.process(pinkRight.process(whiteRight)))
        ) * bedLevel.next() * (1 + 0.45 * gustSwell)
        let tick = tickHighpass.process(random.signedUnit()) * tickEnvelope
        let plop = plopLowpass.process(random.signedUnit()) * plopEnvelope * 2.5
        tickEnvelope *= tickDecay
        plopEnvelope *= plopDecay
        let thunder = thunderSample()
        let drip = dripSample()
        let wet = reverbOutput(for: thunder + drip * 1.4)
        let wind = windVoice.isAudible ? windVoice.sample(whiteLeft: random.signedUnit(), whiteRight: random.signedUnit(), whiteShared: random.signedUnit()) : .zero
        let mix = (bed + tick * 0.5 + plop * 0.8 + wind + thunder * 0.38 + drip + wet * 0.22) * volume.next()
        return limiter.process(mix)
    }

    private func triggerPatter() {
        let rate = patterRate.next() * (1 + 0.7 * gustSwell)
        guard rate > 0, random.unit() < rate * sampleDuration else { return }
        let pan = random.unit()
        let gains = SIMD2(1 - pan, pan) * random.value(in: 0.08...0.5)
        if random.unit() < 0.2 {
            plopEnvelope += gains
        } else {
            tickEnvelope += gains
        }
    }

    private func reverbOutput(for input: SIMD2<Float>) -> SIMD2<Float> {
        if input != .zero {
            reverbTailSamples = reverbTailLength
        } else if reverbTailSamples > 0 {
            reverbTailSamples -= 1
        } else {
            return .zero
        }
        return reverb.process(input)
    }

    private func thunderSample() -> SIMD2<Float> {
        var total = SIMD2<Float>.zero
        for index in thunderVoices.indices where thunderVoices[index].isActive {
            total += thunderVoices[index].sample(whiteLeft: random.signedUnit(), whiteRight: random.signedUnit(), random: &random)
        }
        return total
    }
}
