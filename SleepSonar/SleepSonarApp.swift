import SwiftUI
import UIKit

@main
struct SleepSonarApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var askDonation = false
    @StateObject private var ringer = AlarmRinger.shared

    init() {
        BackgroundAnalysis.register()
        StopAlarmAction.run = { await MainActor.run { SmartAlarm.shared.stopRinging() } }
        SnoozeAlarmAction.run = { await MainActor.run { SmartAlarm.shared.snoozeRinging() } }
        // „Ausblenden“ in der Live-Aktivität
        FadeSoundsAction.run = { await MainActor.run { SleepSoundPlayer.shared.stop(fade: true) } }
        PlaySoundsAction.run = { await MainActor.run { SleepSoundPlayer.shared.play() } }
        StopSoundsAction.run = { await MainActor.run { SleepSoundPlayer.shared.stopSoft() } }
        // Ab iOS 26 schwebende Glas-Tab-Leiste vom System; davor in Nachttinte statt System-Grau
        if #unavailable(iOS 26) {
            let tab = UITabBarAppearance()
            tab.configureWithOpaqueBackground()
            tab.backgroundColor = UIColor(Theme.ink)
            tab.shadowColor = UIColor(Theme.hairline)
            UITabBar.appearance().standardAppearance = tab
            UITabBar.appearance().scrollEdgeAppearance = tab
        }
        // Große Titel in New York
        let nav = UINavigationBarAppearance()
        if #available(iOS 26, *) {
            nav.configureWithTransparentBackground()   // weicher Übergang kommt vom Scroll-Rand
        } else {
            nav.configureWithOpaqueBackground()
            nav.backgroundColor = UIColor(Theme.ink)
        }
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
                    .tabItem { Label(tr("Heute Nacht"), systemImage: "moon.stars") }
                AlarmView()
                    .tabItem { Label(tr("Wecker"), systemImage: "alarm") }
                SoundsView()
                    .tabItem { Label(tr("Klänge"), systemImage: "speaker.wave.2") }
                NightView()
                    .tabItem { Label(tr("Nächte"), systemImage: "chart.bar.xaxis") }
                MoreView()
                    .tabItem { Label(tr("Mehr"), systemImage: "ellipsis.circle") }
            }
            .tint(Theme.moon)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    BackgroundAnalysis.appWentToBackground()
                    SleepSoundPlayer.shared.appBackgrounded()
                }
                if phase == .active { SmartAlarm.shared.refresh() }
            }
            // Einmal bei der Einrichtung fragen (und wieder, wenn sich der Text ändert)
            .onAppear { askDonation = DataDonation.shared.shouldAsk }
            .sheet(isPresented: $askDonation) { DonationConsentView() }
            .fullScreenCover(isPresented: Binding(get: { ringer.ringing != nil }, set: { _ in })) {
                RingingView()
            }
        }
    }
}
