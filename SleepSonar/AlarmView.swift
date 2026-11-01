import SwiftUI

/// Wecker: weckt im eingestellten Zeitraum, sobald du leicht schläfst, spätestens zur Weckzeit.
struct AlarmView: View {
    @ObservedObject private var alarm = SmartAlarm.shared
    @ObservedObject private var rec = PassiveNightEngine.shared

    private let windows = [10, 20, 30, 45, 60]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    if !SmartAlarm.isAvailable {
                        Text(tr("Der Wecker braucht iOS 26 oder neuer."))
                            .font(.callout).foregroundStyle(Theme.mist)
                    } else {
                        Toggle(isOn: $alarm.enabled) {
                            Text(tr("Wecker")).font(Theme.display(24))
                        }
                        .tint(Theme.color(.rem))

                        VStack(alignment: .leading, spacing: 14) {
                            Picker(tr("Wecken nach"), selection: $alarm.mode) {
                                Text(tr("Uhrzeit")).tag(SmartAlarm.Mode.time)
                                Text(tr("Schlafdauer")).tag(SmartAlarm.Mode.duration)
                            }
                            .pickerStyle(.segmented)

                            if alarm.mode == .time { timePicker } else { durationPicker }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle(tr("Leichten Schlaf suchen"))
                            Picker(tr("Zeitraum"), selection: $alarm.windowMinutes) {
                                ForEach(windows, id: \.self) { Text(tr("%d min", $0)).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            Text(windowText)
                                .font(.callout).foregroundStyle(Theme.mist)
                        }

                        if let p = alarm.problem {
                            Text(p).font(.callout).foregroundStyle(Theme.alert)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            note("waveform", tr("Für das Wecken im leichten Schlaf muss die Nachtaufnahme laufen. Ohne Aufnahme klingelt der Wecker zur spätesten Zeit."))
                            note("bell", tr("Er klingelt wie der iPhone-Wecker, auch bei Stummschaltung und im Schlaf-Fokus."))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .nightBackground()
            .navigationTitle(tr("Wecker"))
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.ink, for: .navigationBar)
        }
    }

    private var timePicker: some View {
        DatePicker(tr("Späteste Weckzeit"), selection: Binding(
            get: {
                Calendar.current.date(bySettingHour: alarm.wakeMinutes / 60, minute: alarm.wakeMinutes % 60,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                alarm.wakeMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .colorScheme(.dark)
    }

    private var durationPicker: some View {
        HStack(spacing: 0) {
            Picker(tr("Stunden"), selection: Binding(
                get: { alarm.durationMinutes / 60 },
                set: { alarm.durationMinutes = $0 * 60 + alarm.durationMinutes % 60 })) {
                    ForEach(3...12, id: \.self) { Text(tr("%d h", $0)).tag($0) }
                }
            Picker(tr("Minuten"), selection: Binding(
                get: { alarm.durationMinutes % 60 / 5 * 5 },
                set: { alarm.durationMinutes = alarm.durationMinutes / 60 * 60 + $0 })) {
                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(tr("%d min", $0)).tag($0) }
                }
        }
        .pickerStyle(.wheel)
        .frame(height: 160)
        .colorScheme(.dark)
    }

    /// Was der Wecker heute tun wird, in einem Satz
    private var windowText: String {
        let w = alarm.windowMinutes
        switch alarm.mode {
        case .time:
            let latest = rec.isRunning ? (alarm.latest ?? alarm.nextWakeTime()) : alarm.nextWakeTime()
            let from = latest.addingTimeInterval(-Double(w) * 60)
            return tr("Weckt zwischen %@ und %@, sobald du leicht schläfst. Spätestens um %@.",
                      from.formatted(date: .omitted, time: .shortened),
                      latest.formatted(date: .omitted, time: .shortened),
                      latest.formatted(date: .omitted, time: .shortened))
        case .duration:
            let dur = NightAnalysisView.hm(Double(alarm.durationMinutes) * 60)
            if rec.isRunning, let latest = alarm.latest {
                return tr("Weckt nach etwa %@ Schlaf: zwischen %@ und %@, sobald du leicht schläfst.", dur,
                          latest.addingTimeInterval(-Double(w) * 60).formatted(date: .omitted, time: .shortened),
                          latest.formatted(date: .omitted, time: .shortened))
            }
            return tr("Weckt nach etwa %@ Schlaf, gerechnet ab dem Einschlafen. In den letzten %d min davor, sobald du leicht schläfst.", dur, w)
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.mist)
            Text(text).font(.callout).foregroundStyle(Theme.mist)
        }
    }
}
