import SwiftUI

/// Main entry point for the Helvetra translation app.
@main
struct HelvetraApp: App {
    init() {
        // Register default values for UserDefaults
        UserDefaults.standard.register(defaults: [
            "hapticsEnabled": true
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
