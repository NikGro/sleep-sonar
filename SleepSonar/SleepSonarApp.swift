import SwiftUI

@main
struct SleepSonarApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                SonarTestView()
                    .tabItem { Label("Sonar", systemImage: "waveform") }
                HealthTestView()
                    .tabItem { Label("Health", systemImage: "heart.text.square") }
            }
        }
    }
}
