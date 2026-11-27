import AVFoundation
import AudioToolbox

final class RainSoundEngine {
    private let engine = AVAudioEngine()
    private var synth: RainSynth?
    private var sourceNode: AVAudioSourceNode?
    private var graphSampleRate: Double = 0
    private var isActive = false
    private var profile = SoundProfile.silent
    private var volume: Float = 0
    private var configurationObserver: NSObjectProtocol?
    private var pendingStop: DispatchWorkItem?

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    deinit {
        configurationObserver.map(NotificationCenter.default.removeObserver)
        engine.stop()
    }

    func update(isActive: Bool, profile: SoundProfile, volume: Float) {
        self.isActive = isActive
        self.profile = profile
        self.volume = volume
        guard isActive else {
            fadeOutAndStop()
            return
        }
        pendingStop?.cancel()
        pendingStop = nil
        activate()
    }

    func thunder(distance: Float) {
        guard isActive else { return }
        synth?.requestThunder(distance: distance)
    }

    private func activate() {
        guard let synth = preparedSynth() else { return }
        synth.profile = profile
        synth.masterVolume = volume
        guard !startEngineIfNeeded() else { return }
        FrameDiagnostics.log("audio engine retrying with a rebuilt graph")
        tearDownGraph()
        guard let rebuilt = preparedSynth() else { return }
        rebuilt.profile = profile
        rebuilt.masterVolume = volume
        _ = startEngineIfNeeded()
    }

    private var outputSampleRate: Double {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return rate > 0 ? rate : 48_000
    }

    private func preparedSynth() -> RainSynth? {
        let sampleRate = outputSampleRate
        if let synth, abs(graphSampleRate - sampleRate) < 1 { return synth }
        tearDownGraph()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }
        let synth = RainSynth(sampleRate: Float(sampleRate))
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard
                buffers.count >= 2,
                let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            synth.render(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.synth = synth
        sourceNode = node
        graphSampleRate = sampleRate
        return synth
    }

    private func tearDownGraph() {
        if engine.isRunning {
            engine.stop()
        }
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        sourceNode = nil
        synth = nil
        graphSampleRate = 0
    }

    private func startEngineIfNeeded() -> Bool {
        guard !engine.isRunning else { return true }
        requestLargeIOBuffer()
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            FrameDiagnostics.log("audio engine failed to start: \(error.localizedDescription)")
            return false
        }
    }

    private func requestLargeIOBuffer() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var frames: UInt32 = 2048
        let status = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            FrameDiagnostics.log("audio buffer size request failed: \(status)")
        }
    }

    private func fadeOutAndStop() {
        guard let synth, engine.isRunning, pendingStop == nil else { return }
        synth.masterVolume = 0
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isActive else { return }
            self.engine.pause()
            self.pendingStop = nil
        }
        pendingStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func restartAfterConfigurationChange() {
        FrameDiagnostics.log("audio configuration changed, output rate \(outputSampleRate)")
        guard isActive else { return }
        activate()
    }
}
