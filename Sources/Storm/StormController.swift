import Foundation

struct LightningStrike {
    let distance: Float
    let seed: UInt64
    let boltScreenIndex: Int?
    let reducesFlashing: Bool

    var showsBolt: Bool {
        distance < 0.4
    }

    var thunderDelay: TimeInterval {
        TimeInterval(0.05 + distance * 6)
    }
}

final class StormController {
    var onStrike: ((LightningStrike) -> Void)?
    private var timer: Timer?
    private var random = FastRandom()
    private var activeIntensity: RainIntensity?
    private var screenCount = 1

    func update(isActive: Bool, intensity: RainIntensity, screenCount: Int) {
        self.screenCount = max(screenCount, 1)
        let interval = isActive ? Self.strikeInterval(for: intensity) : nil
        guard interval != nil else {
            cancel()
            return
        }
        guard timer == nil || activeIntensity != intensity else { return }
        activeIntensity = intensity
        scheduleNext()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        activeIntensity = nil
    }

    func strikeNow(distance: Float) {
        strike(distance: distance)
    }

    private func scheduleNext() {
        timer?.invalidate()
        guard let intensity = activeIntensity, let range = Self.strikeInterval(for: intensity) else { return }
        let delay = TimeInterval(random.value(in: range))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.strike(distance: self.random.value(in: 0.05...1))
            self.scheduleNext()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func strike(distance: Float) {
        let strike = LightningStrike(
            distance: distance,
            seed: random.next(),
            boltScreenIndex: random.integer(in: 0...(screenCount - 1)),
            reducesFlashing: NSWorkspaceAccessibility.reducesMotion
        )
        onStrike?(strike)
    }

    private static func strikeInterval(for intensity: RainIntensity) -> ClosedRange<Float>? {
        switch intensity {
        case .drizzle: return nil
        case .rain: return 45...110
        case .downpour: return 12...40
        }
    }
}
