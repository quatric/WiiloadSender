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

enum Platform: Int, CaseIterable, Identifiable {
    case wii = 0, wiiU, ds3, nx
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .wii: return "Wii"
        case .wiiU: return "Wii U"
        case .ds3: return "3DS"
        case .nx: return "Switch"
        }
    }
    var defaultPort: UInt16 {
        switch self {
        case .wii, .wiiU: return 4299
        case .ds3: return 17491
        case .nx: return 28280
        }
    }
    var protocolName: String {
        switch self {
        case .wii, .wiiU: return "wiiload"
        case .ds3: return "3dslink"
        case .nx: return "nxlink"
        }
    }
    var usesLinkProtocol: Bool { self == .ds3 || self == .nx }
    var hint: String {
        switch self {
        case .wii: return "Start the Homebrew Channel on your Wii (it waits for a connection) and join the same Wi-Fi network."
        case .wiiU: return "Start the Homebrew Launcher on your Wii U (with the wiiload/network loader enabled) on the same Wi-Fi network."
        case .ds3: return "Open the Homebrew Launcher on your 3DS and press Y to start the NetLoader."
        case .nx: return "Open the Homebrew Menu on your Switch and press Y to start NetLoader."
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

    @Published var platform: Platform {
        didSet {
            UserDefaults.standard.set(platform.rawValue, forKey: Keys.platform)
            if platform != oldValue { port = Int(platform.defaultPort) }
        }
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
        static let platform = "platform"
    }

    init() {
        let defaults = UserDefaults.standard
        self.lastIPAddress = defaults.string(forKey: Keys.lastIP) ?? ""
        let plat = Platform(rawValue: defaults.integer(forKey: Keys.platform)) ?? .wii
        self.platform = plat
        let storedPort = defaults.integer(forKey: Keys.port)
        self.port = (1...65535).contains(storedPort) ? storedPort : Int(plat.defaultPort)
        self.arguments = defaults.string(forKey: Keys.arguments) ?? ""
        let storedAppearance = defaults.integer(forKey: Keys.appearance)
        self.appearance = AppearanceMode(rawValue: storedAppearance) ?? .system
    }
}
