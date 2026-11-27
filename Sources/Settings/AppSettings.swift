import Foundation

enum RainIntensity: String, CaseIterable {
    case drizzle
    case rain
    case downpour

    var title: String {
        switch self {
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .downpour: return "Downpour"
        }
    }

    var densityFraction: Float {
        switch self {
        case .drizzle: return 0.2
        case .rain: return 0.55
        case .downpour: return 1.0
        }
    }

    var speedRange: ClosedRange<Float> {
        switch self {
        case .drizzle: return 520...780
        case .rain: return 850...1200
        case .downpour: return 1050...1450
        }
    }

    var streakDuration: Float {
        switch self {
        case .drizzle: return 0.012
        case .rain: return 0.016
        case .downpour: return 0.019
        }
    }

    var widthRange: ClosedRange<Float> {
        switch self {
        case .drizzle: return 0.7...1.0
        case .rain: return 0.9...1.3
        case .downpour: return 1.0...1.6
        }
    }

    var splashStrength: Float {
        switch self {
        case .drizzle: return 0.6
        case .rain: return 0.85
        case .downpour: return 1.0
        }
    }
}

enum ScreenSelection: String, CaseIterable {
    case allScreens
    case primaryOnly

    var title: String {
        switch self {
        case .allScreens: return "All Displays"
        case .primaryOnly: return "Main Display (Desktop 1)"
        }
    }
}

final class AppSettings {
    static let didChangeNotification = Notification.Name("RaindropsSettingsDidChange")
    static let dropCountOptions = [1000, 2000, 3000, 4000]
    static let windRange: ClosedRange<Double> = 0...1
    static let windLevels: [Double] = [0, 0.25, 0.5, 0.75, 1]
    static let windStep = 0.25
    static let windTitles = ["Calm", "Light", "Moderate", "Strong", "Storm"]

    static func windTitle(for wind: Double) -> String {
        let index = windLevels.firstIndex(of: nearestWindLevel(to: wind)) ?? 0
        return windTitles[min(index, windTitles.count - 1)]
    }

    static func nearestWindLevel(to value: Double) -> Double {
        windLevels.min { abs($0 - value) < abs($1 - value) } ?? 0
    }
    static let poolFractionRange: ClosedRange<Double> = 0.02...0.5
    static let volumeRange: ClosedRange<Double> = 0...1

    private enum Key {
        static let isEnabled = "isEnabled"
        static let intensity = "intensity"
        static let wind = "wind"
        static let maximumDropCount = "maximumDropCount"
        static let isPoolEnabled = "isPoolEnabled"
        static let poolMaximumFraction = "poolMaximumFraction"
        static let isCursorInteractionEnabled = "isCursorInteractionEnabled"
        static let screenSelection = "screenSelection"
        static let isSoundEnabled = "isSoundEnabled"
        static let soundVolume = "soundVolume"
        static let isStormEnabled = "isStormEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.isEnabled: true,
            Key.intensity: RainIntensity.rain.rawValue,
            Key.wind: 0.25,
            Key.maximumDropCount: 2000,
            Key.isPoolEnabled: true,
            Key.poolMaximumFraction: 0.08,
            Key.isCursorInteractionEnabled: true,
            Key.screenSelection: ScreenSelection.allScreens.rawValue,
            Key.isSoundEnabled: true,
            Key.soundVolume: 0.5,
            Key.isStormEnabled: true
        ])
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.isEnabled) }
        set { store(newValue, forKey: Key.isEnabled) }
    }

    var intensity: RainIntensity {
        get { RainIntensity(rawValue: defaults.string(forKey: Key.intensity) ?? "") ?? .rain }
        set { store(newValue.rawValue, forKey: Key.intensity) }
    }

    var wind: Double {
        get { Self.nearestWindLevel(to: abs(defaults.double(forKey: Key.wind))) }
        set { store(Self.nearestWindLevel(to: newValue), forKey: Key.wind) }
    }

    var maximumDropCount: Int {
        get { max(200, defaults.integer(forKey: Key.maximumDropCount)) }
        set { store(newValue, forKey: Key.maximumDropCount) }
    }

    var isPoolEnabled: Bool {
        get { defaults.bool(forKey: Key.isPoolEnabled) }
        set { store(newValue, forKey: Key.isPoolEnabled) }
    }

    var poolMaximumFraction: Double {
        get { defaults.double(forKey: Key.poolMaximumFraction).clamped(to: Self.poolFractionRange) }
        set { store(newValue.clamped(to: Self.poolFractionRange), forKey: Key.poolMaximumFraction) }
    }

    var isCursorInteractionEnabled: Bool {
        get { defaults.bool(forKey: Key.isCursorInteractionEnabled) }
        set { store(newValue, forKey: Key.isCursorInteractionEnabled) }
    }

    var screenSelection: ScreenSelection {
        get { ScreenSelection(rawValue: defaults.string(forKey: Key.screenSelection) ?? "") ?? .allScreens }
        set { store(newValue.rawValue, forKey: Key.screenSelection) }
    }

    var isSoundEnabled: Bool {
        get { defaults.bool(forKey: Key.isSoundEnabled) }
        set { store(newValue, forKey: Key.isSoundEnabled) }
    }

    var soundVolume: Double {
        get { defaults.double(forKey: Key.soundVolume).clamped(to: Self.volumeRange) }
        set { store(newValue.clamped(to: Self.volumeRange), forKey: Key.soundVolume) }
    }

    var isStormEnabled: Bool {
        get { defaults.bool(forKey: Key.isStormEnabled) }
        set { store(newValue, forKey: Key.isStormEnabled) }
    }

    private func store(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
