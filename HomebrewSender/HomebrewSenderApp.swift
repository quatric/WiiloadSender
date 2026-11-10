import SwiftUI

@main
struct HomebrewSenderApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .onAppear { settings.appearance.apply() }
                .onChange(of: settings.appearance) { newValue in newValue.apply() }
        }
    }
}
