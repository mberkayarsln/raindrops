import AVFoundation
import AudioToolbox

final class RainSoundEngine {
    private let engine = AVAudioEngine()
    private var synth: RainSynth?
    private var sourceNode: AVAudioSourceNode?
    private var isActive = false
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
        guard isActive else {
            fadeOutAndStop()
            return
        }
        pendingStop?.cancel()
        pendingStop = nil
        guard let synth = preparedSynth() else { return }
        synth.profile = profile
        synth.masterVolume = volume
        startEngineIfNeeded()
    }

    func thunder(distance: Float) {
        guard isActive else { return }
        synth?.requestThunder(distance: distance)
    }

    private func preparedSynth() -> RainSynth? {
        if let synth { return synth }
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 48_000
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
        return synth
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        requestLargeIOBuffer()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            FrameDiagnostics.log("audio engine failed to start: \(error.localizedDescription)")
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
        guard isActive else { return }
        startEngineIfNeeded()
    }
}
