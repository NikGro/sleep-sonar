import SwiftUI

@main
struct SleepSonarApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                NightView()
                    .tabItem { Label("Nacht", systemImage: "moon.stars") }
                SonarTestView()
                    .tabItem { Label("Sonar", systemImage: "waveform") }
                HealthTestView()
                    .tabItem { Label("Health", systemImage: "heart.text.square") }
            }
        }
    }
}
