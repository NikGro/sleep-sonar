import SwiftUI
import UIKit

@main
struct SleepSonarApp: App {
    init() {
        // Tab-Leiste in Nachttinte statt System-Grau
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Theme.ink)
        tab.shadowColor = UIColor(Theme.hairline)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        // Große Titel in New York
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Theme.ink)
        nav.shadowColor = .clear
        let serif = UIFont.systemFont(ofSize: 34, weight: .regular).fontDescriptor.withDesign(.serif)
        if let serif {
            nav.largeTitleTextAttributes = [.font: UIFont(descriptor: serif, size: 34),
                                            .foregroundColor: UIColor(Theme.moon)]
        }
        let small = UIFont.systemFont(ofSize: 17, weight: .semibold).fontDescriptor.withDesign(.serif)
        if let small {
            nav.titleTextAttributes = [.font: UIFont(descriptor: small, size: 17),
                                       .foregroundColor: UIColor(Theme.moon)]
        }
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            // Sonar ist vorerst ausgesetzt (Code bleibt erhalten: SonarTestView / SonarEngine)
            TabView {
                TonightView()
                    .tabItem { Label("Heute Nacht", systemImage: "moon.stars") }
                NightView()
                    .tabItem { Label("Nächte", systemImage: "chart.bar.xaxis") }
                MoreView()
                    .tabItem { Label("Mehr", systemImage: "ellipsis.circle") }
            }
            .tint(Theme.moon)
            .preferredColorScheme(.dark)
        }
    }
}
