import Foundation

#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class RemoteSessionSettingsStore {
    static let shared = RemoteSessionSettingsStore()

    private enum Keys {
        static let hostingEnabled = "remoteSession.hostingEnabled"
        static let pin = "remoteSession.pin"
        static let displayName = "remoteSession.displayName"
    }

    private let defaults: UserDefaults

    var isHostingEnabled: Bool {
        didSet { defaults.set(isHostingEnabled, forKey: Keys.hostingEnabled) }
    }

    var pin: String {
        didSet { defaults.set(pin, forKey: Keys.pin) }
    }

    var displayName: String {
        didSet { defaults.set(displayName, forKey: Keys.displayName) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let resolvedPIN: String
        if let storedPin = defaults.string(forKey: Keys.pin), Self.isValidPIN(storedPin) {
            resolvedPIN = storedPin
        } else {
            resolvedPIN = Self.generatePIN()
            defaults.set(resolvedPIN, forKey: Keys.pin)
        }

        let resolvedName: String
        if let storedName = defaults.string(forKey: Keys.displayName), !storedName.isEmpty {
            resolvedName = storedName
        } else {
            resolvedName = Self.defaultDisplayName()
            defaults.set(resolvedName, forKey: Keys.displayName)
        }

        pin = resolvedPIN
        displayName = resolvedName
        isHostingEnabled = defaults.bool(forKey: Keys.hostingEnabled)
    }

    func regeneratePIN() {
        pin = Self.generatePIN()
    }

    func enableHosting() {
        if !Self.isValidPIN(pin) {
            regeneratePIN()
        }
        isHostingEnabled = true
    }

    func disableHosting() {
        isHostingEnabled = false
    }

    static func generatePIN() -> String {
        let max = Int(pow(10.0, Double(RemoteSessionBonjour.pinLength)))
        let value = Int.random(in: 0..<max)
        return String(format: "%0\(RemoteSessionBonjour.pinLength)d", value)
    }

    static func isValidPIN(_ pin: String) -> Bool {
        pin.count == RemoteSessionBonjour.pinLength && pin.allSatisfy(\.isNumber)
    }

    static func defaultDisplayName() -> String {
        #if os(macOS)
        ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        #else
        UIDevice.current.name
        #endif
    }
}
