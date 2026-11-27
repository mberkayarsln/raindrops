import Foundation

struct SimulationConfiguration: Equatable {
    var intensity: RainIntensity = .rain
    var windSchedule = WindSchedule.steady(strength: 0)
    var windDirection = WindDirection.shifting
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

    init() {}

    init(settings: AppSettings, isLowPowerModeEnabled: Bool, windSchedule: WindSchedule? = nil) {
        intensity = settings.intensity
        self.windSchedule = windSchedule ?? .steady(strength: Float(settings.wind))
        windDirection = settings.windDirection
        maximumDropCount = settings.maximumDropCount
        isPoolEnabled = settings.isPoolEnabled
        poolMaximumFraction = Float(settings.poolMaximumFraction)
        isCursorInteractionEnabled = settings.isCursorInteractionEnabled
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}
