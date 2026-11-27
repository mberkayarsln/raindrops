import ColorSync
import CoreGraphics
import Foundation

struct PrimaryDesktopState: Equatable {
    let firstDesktopID: Int
    let currentSpaceID: Int

    var isOnFirstDesktop: Bool {
        firstDesktopID == currentSpaceID
    }
}

final class SpaceTracker {
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias ManagedSpacesFunction = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let desktopSpaceType = 0

    private let connection: Int32?
    private let copyManagedSpaces: ManagedSpacesFunction?

    init() {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        let connectionSymbol = dlsym(defaultHandle, "CGSMainConnectionID")
        let spacesSymbol = dlsym(defaultHandle, "CGSCopyManagedDisplaySpaces")
        connection = connectionSymbol.map { unsafeBitCast($0, to: ConnectionFunction.self)() }
        copyManagedSpaces = spacesSymbol.map { unsafeBitCast($0, to: ManagedSpacesFunction.self) }
    }

    func primaryDesktopState() -> PrimaryDesktopState? {
        guard
            let connection,
            let copyManagedSpaces,
            let displays = copyManagedSpaces(connection)?.takeRetainedValue() as? [[String: Any]],
            let display = mainDisplayEntry(in: displays),
            let firstDesktop = firstDesktopID(in: display),
            let current = (display["Current Space"] as? [String: Any]).flatMap(Self.spaceID(of:))
        else { return nil }
        return PrimaryDesktopState(firstDesktopID: firstDesktop, currentSpaceID: current)
    }

    private func mainDisplayEntry(in displays: [[String: Any]]) -> [String: Any]? {
        let identifier = Self.mainDisplayIdentifier()
        return displays.first { entry in
            let entryIdentifier = entry["Display Identifier"] as? String
            return entryIdentifier == "Main" || entryIdentifier?.caseInsensitiveCompare(identifier ?? "") == .orderedSame
        } ?? displays.first
    }

    private func firstDesktopID(in display: [String: Any]) -> Int? {
        let spaces = display["Spaces"] as? [[String: Any]] ?? []
        let firstDesktop = spaces.first { ($0["type"] as? NSNumber)?.intValue == Self.desktopSpaceType }
        return firstDesktop.flatMap(Self.spaceID(of:))
    }

    private static func spaceID(of space: [String: Any]) -> Int? {
        (space["ManagedSpaceID"] as? NSNumber)?.intValue ?? (space["id64"] as? NSNumber)?.intValue
    }

    private static func mainDisplayIdentifier() -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
