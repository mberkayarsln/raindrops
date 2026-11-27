import AppKit
import CoreGraphics
import QuartzCore

struct WindowRecord {
    let id: UInt32
    var frame: CGRect
    let order: Int
}

struct WindowSnapshot {
    let timestamp: CFTimeInterval
    let windows: [WindowRecord]
}

final class WindowGeometryProvider {
    static let pollInterval: CFTimeInterval = 1.0 / 18.0

    private let queue = DispatchQueue(label: "app.raindrops.geometry", qos: .userInteractive)
    private let lock = NSLock()
    private let ownProcessID = getpid()
    private var timer: DispatchSourceTimer?
    private var previous: WindowSnapshot?
    private var latest: WindowSnapshot?
    private var primaryScreenHeight: CGFloat = 0
    private var cachedTime: CFTimeInterval = -1
    private var cachedWindows: [WindowRecord] = []

    func updateScreenMetrics() {
        let height = NSScreen.screens.first?.frame.height ?? 0
        lock.withLock { primaryScreenHeight = height }
    }

    func start() {
        guard timer == nil else { return }
        updateScreenMetrics()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(4))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.withLock {
            previous = nil
            latest = nil
        }
    }

    func windows(at time: CFTimeInterval) -> [WindowRecord] {
        if time == cachedTime { return cachedWindows }
        let pair = lock.withLock { (previous, latest) }
        cachedWindows = Self.interpolate(from: pair.0, to: pair.1, at: time)
        cachedTime = time
        return cachedWindows
    }

    static func currentWindows() -> [WindowRecord] {
        let provider = WindowGeometryProvider()
        provider.updateScreenMetrics()
        let height = provider.lock.withLock { provider.primaryScreenHeight }
        return provider.readWindows(primaryScreenHeight: height)
    }

    static func dumpCurrentWindows() {
        let provider = WindowGeometryProvider()
        provider.updateScreenMetrics()
        let height = provider.lock.withLock { provider.primaryScreenHeight }
        let start = CACurrentMediaTime()
        let iterations = 50
        for _ in 0..<iterations { _ = provider.readWindows(primaryScreenHeight: height) }
        print("window list read meanMs=\(String(format: "%.3f", (CACurrentMediaTime() - start) / Double(iterations) * 1000))")
        for record in provider.readWindows(primaryScreenHeight: height) {
            print("window id=\(record.id) order=\(record.order) appKitFrame=\(record.frame)")
        }
    }

    private func poll() {
        let height = lock.withLock { primaryScreenHeight }
        let records = readWindows(primaryScreenHeight: height)
        let snapshot = WindowSnapshot(timestamp: CACurrentMediaTime(), windows: records)
        lock.withLock {
            previous = latest
            latest = snapshot
        }
    }

    private func readWindows(primaryScreenHeight: CGFloat) -> [WindowRecord] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var records: [WindowRecord] = []
        records.reserveCapacity(entries.count)
        for entry in entries {
            guard let frame = appKitFrame(of: entry, primaryScreenHeight: primaryScreenHeight), let id = windowNumber(of: entry) else { continue }
            records.append(WindowRecord(id: id, frame: frame, order: records.count))
        }
        return records
    }

    private func windowNumber(of entry: [String: Any]) -> UInt32? {
        (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }

    private func appKitFrame(of entry: [String: Any], primaryScreenHeight: CGFloat) -> CGRect? {
        guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
        guard let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner != ownProcessID else { return nil }
        if let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.05 { return nil }
        guard
            let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
            bounds.width >= 60, bounds.height >= 40
        else { return nil }
        return CoordinateSpace.appKitRect(fromQuartz: bounds, primaryScreenHeight: primaryScreenHeight)
    }

    private static func interpolate(from previous: WindowSnapshot?, to latest: WindowSnapshot?, at time: CFTimeInterval) -> [WindowRecord] {
        guard let latest else { return [] }
        guard let previous, latest.timestamp > previous.timestamp else { return latest.windows }
        let interval = latest.timestamp - previous.timestamp
        let progress = CGFloat(((time - latest.timestamp) / interval).clamped(to: 0...1))
        var previousFrames: [UInt32: CGRect] = [:]
        previousFrames.reserveCapacity(previous.windows.count)
        for record in previous.windows { previousFrames[record.id] = record.frame }
        return latest.windows.map { record in
            guard let start = previousFrames[record.id] else { return record }
            var blended = record
            blended.frame = start.interpolated(to: record.frame, progress: progress)
            return blended
        }
    }
}

enum CoordinateSpace {
    static func appKitRect(fromQuartz rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension CGRect {
    func interpolated(to target: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: minX + (target.minX - minX) * progress,
            y: minY + (target.minY - minY) * progress,
            width: width + (target.width - width) * progress,
            height: height + (target.height - height) * progress
        )
    }
}
