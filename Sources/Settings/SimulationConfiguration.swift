import Foundation

struct SimulationConfiguration: Equatable {
    var intensity: RainIntensity = .rain
    var wind: Float = 0
    var maximumDropCount = 2000
    var isPoolEnabled = true
    var poolMaximumFraction: Float = 0.08
    var isCursorInteractionEnabled = true
    var isLowPowerModeEnabled = false

    var targetDropCount: Int {
        let base = Float(maximumDropCount) * intensity.densityFraction
        return Int(isLowPowerModeEnabled ? base * 0.5 : base)
    }

    var splashCapacity: Int {
        isLowPowerModeEnabled ? maximumDropCount : maximumDropCount * 2
    }

    var windAngle: Float {
        wind * 0.5
    }

    init() {}

    init(settings: AppSettings, isLowPowerModeEnabled: Bool) {
        intensity = settings.intensity
        wind = Float(settings.wind)
        maximumDropCount = settings.maximumDropCount
        isPoolEnabled = settings.isPoolEnabled
        poolMaximumFraction = Float(settings.poolMaximumFraction)
        isCursorInteractionEnabled = settings.isCursorInteractionEnabled
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}
