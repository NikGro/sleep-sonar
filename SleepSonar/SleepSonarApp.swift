import SwiftUI

@main
struct SleepSonarApp: App {
    var body: some Scene {
        WindowGroup {
            // Sonar ist vorerst ausgesetzt (Code bleibt erhalten: SonarTestView / SonarEngine)
            TabView {
                NightView()
                    .tabItem { Label("Nacht", systemImage: "moon.stars") }
                HealthTestView()
                    .tabItem { Label("Health", systemImage: "heart.text.square") }
            }
        }
    }
}
