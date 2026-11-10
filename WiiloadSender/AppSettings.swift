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

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Applies the style to every window so sheets (e.g. Settings) follow it too.
    @MainActor
    func apply() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = interfaceStyle }
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

    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: Keys.port) }
    }

    @Published var arguments: String {
        didSet { UserDefaults.standard.set(arguments, forKey: Keys.arguments) }
    }

    private enum Keys {
        static let port = "port"
        static let arguments = "arguments"
        static let lastIP = "lastIPAddress"
        static let appearance = "appearanceMode"
    }

    init() {
        let defaults = UserDefaults.standard
        self.lastIPAddress = defaults.string(forKey: Keys.lastIP) ?? ""
        let storedPort = defaults.integer(forKey: Keys.port)
        self.port = (1...65535).contains(storedPort) ? storedPort : Int(WiiloadClient.defaultPort)
        self.arguments = defaults.string(forKey: Keys.arguments) ?? ""
        let storedAppearance = defaults.integer(forKey: Keys.appearance)
        self.appearance = AppearanceMode(rawValue: storedAppearance) ?? .system
    }
}
