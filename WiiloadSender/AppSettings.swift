import SwiftUI
import Combine

enum AppearanceMode: Int, CaseIterable, Identifiable {
    case system = 0
    case light = 1
    case dark = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class AppSettings: ObservableObject {
    @Published var lastIPAddress: String {
        didSet { UserDefaults.standard.set(lastIPAddress, forKey: Keys.lastIP) }
    }

    @Published var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    private enum Keys {
        static let lastIP = "lastIPAddress"
        static let appearance = "appearanceMode"
    }

    init() {
        let defaults = UserDefaults.standard
        self.lastIPAddress = defaults.string(forKey: Keys.lastIP) ?? ""
        let storedAppearance = defaults.integer(forKey: Keys.appearance)
        self.appearance = AppearanceMode(rawValue: storedAppearance) ?? .system
    }
}
