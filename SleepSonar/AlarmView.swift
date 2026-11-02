import SwiftUI
import UniformTypeIdentifiers

/// Wecker-Liste: jeder Wecker mit Zeit, Beschreibung, Wiederholung und Schalter.
struct AlarmView: View {
    @ObservedObject private var alarms = SmartAlarm.shared
    @State private var editing: AlarmItem?

    var body: some View {
        NavigationStack {
            List {
                if !SmartAlarm.isAvailable {
                    Text(tr("Der Wecker braucht iOS 26 oder neuer."))
                        .font(.callout).foregroundStyle(Theme.mist)
                        .listRowBackground(Theme.ink)
                } else if alarms.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Noch kein Wecker")).font(Theme.display(22))
                        Text(tr("Tippe auf +, um einen Wecker anzulegen. Er kann dich im leichten Schlaf wecken, solange die Nachtaufnahme läuft."))
                            .font(.callout).foregroundStyle(Theme.mist)
                    }
                    .padding(.vertical, 24)
                    .listRowBackground(Theme.ink)
                }
                ForEach(alarms.snoozing.sorted { $0.value < $1.value }, id: \.key) { kit, until in
                    HStack(spacing: 12) {
                        Image(systemName: "zzz").foregroundStyle(Theme.accent)
                        Text(tr("Schlummert bis %@", until.formatted(date: .omitted, time: .shortened)))
                            .foregroundStyle(Theme.moon)
                        Spacer()
                        Button(tr("Beenden")) { Haptics.tap(); alarms.endSnooze(kit) }
                            .buttonStyle(.bordered)
                            .tint(Theme.accent)
                    }
                    .listRowBackground(Theme.raised)
                }
                ForEach(alarms.items) { a in
                    AlarmRow(item: a) { on in Haptics.select(); alarms.setEnabled(a.id, on) }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = a }
                        .listRowBackground(Theme.ink)
                        .listRowSeparatorTint(Theme.hairline)
                }
                .onDelete { idx in idx.map { alarms.items[$0].id }.forEach(alarms.delete) }

                if let p = alarms.problem {
                    Text(p).font(.callout).foregroundStyle(Theme.alert).listRowBackground(Theme.ink)
                }
                if SmartAlarm.isAvailable {
                    VStack(alignment: .leading, spacing: 10) {
                        note("waveform", tr("Im leichten Schlaf wecken geht nur, während die Nachtaufnahme läuft. Ohne Aufnahme klingelt jeder Wecker zur eingestellten Zeit."))
                        note("bell", tr("Die Wecker klingeln wie der iPhone-Wecker, auch bei Stummschaltung und im Schlaf-Fokus."))
                    }
                    .padding(.top, 16)
                    .listRowBackground(Theme.ink)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .nightBackground()
            .navigationTitle(tr("Wecker"))
            .toolbarTitleDisplayMode(.inlineLarge)   // großer Titel in einer Zeile mit den Knöpfen
            .suyaTopEdge()
            .toolbar {
                if SmartAlarm.isAvailable {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Haptics.tap(); editing = AlarmItem() } label: { Image(systemName: "plus") }
                            .accessibilityLabel(tr("Wecker hinzufügen"))
                    }
                }
            }
            .onAppear { if DemoScreens.screen == "alarmEdit", editing == nil { editing = AlarmItem() } }
            .sheet(item: $editing) { item in
                AlarmEditView(item: item, isNew: !alarms.items.contains { $0.id == item.id })
            }
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.mist)
            Text(text).font(.callout).foregroundStyle(Theme.mist)
        }
    }
}

private struct AlarmRow: View {
    let item: AlarmItem
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mainText)
                    .font(Theme.display(40, weight: .light).monospacedDigit())
                    .foregroundStyle(item.enabled ? Theme.moon : Theme.mist)
                Text(AlarmEditView.summary(item))
                    .font(.callout).foregroundStyle(Theme.mist)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { item.enabled }, set: toggle))
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var mainText: String {
        switch item.mode {
        case .time:
            let d = Calendar.current.date(bySettingHour: item.wakeMinutes / 60, minute: item.wakeMinutes % 60,
                                          second: 0, of: Date()) ?? Date()
            return d.formatted(date: .omitted, time: .shortened)
        case .duration:
            return NightAnalysisView.hm(Double(item.durationMinutes) * 60)
        }
    }
}

/// Wecker anlegen oder ändern – aufgebaut wie in der Uhr-App.
struct AlarmEditView: View {
    @State var item: AlarmItem
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("alarm.durationHintHidden") private var hideDurationHint = false
    @State private var showDurationHint = false
    private let windows = [10, 20, 30, 45, 60]
    private let snoozes = [1, 3, 5, 9, 10, 15, 20, 30]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(tr("Wecken nach"), selection: $item.mode) {
                        Text(tr("Uhrzeit")).tag(AlarmItem.Mode.time)
                        Text(tr("Schlafdauer")).tag(AlarmItem.Mode.duration)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    if item.mode == .time { timePicker } else { durationPicker }
                }
                .listRowBackground(Color.clear)

                Section {
                    if item.mode == .time {
                        NavigationLink {
                            RepeatList(days: $item.repeatDays)
                        } label: {
                            LabeledContent(tr("Wiederholen"), value: WeekdayPicker.describe(item.repeatDays))
                        }
                    }
                    LabeledContent(tr("Bezeichnung")) {
                        TextField(tr("Wecker"), text: $item.label)
                            .multilineTextAlignment(.trailing)
                    }
                    NavigationLink {
                        SoundList(item: $item)
                    } label: {
                        LabeledContent(tr("Ton"), value: soundName)
                    }
                    Toggle(tr("Schlummern"), isOn: $item.snooze).tint(Theme.accent)
                    if item.snooze {
                        Picker(tr("Schlummerdauer"), selection: $item.snoozeMinutes) {
                            ForEach(snoozes, id: \.self) { Text(tr("%d min", $0)).tag($0) }
                        }
                    }
                }
                .listRowBackground(Theme.raised)

                Section {
                    Toggle(tr("Im leichten Schlaf wecken"), isOn: $item.smart).tint(Theme.accent)
                    if item.smart {
                        Picker(tr("Zeitraum"), selection: $item.windowMinutes) {
                            ForEach(windows, id: \.self) { Text(tr("%d min", $0)).tag($0) }
                        }
                    }
                } footer: {
                    Text(item.smart ? tr("Weckt in den letzten %d min vor der spätesten Zeit, sobald du leicht schläfst. Dafür muss die Nachtaufnahme laufen.", item.windowMinutes)
                                    : tr("Klingelt genau zur eingestellten Zeit."))
                }
                .listRowBackground(Theme.raised)

                if !isNew {
                    Section {
                        Button(tr("Wecker löschen"), role: .destructive) {
                            SmartAlarm.shared.delete(item.id)
                            Haptics.warning()
                            dismiss()
                        }
                        .foregroundStyle(Theme.alert)
                        .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Theme.raised)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // runde Glas-Knöpfe wie in der Uhr-App (gleich breit → Titel genau mittig)
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(tr("Abbrechen"))
                }
                // Titel selbst mittig setzen (die Systemtitelzeile rückte ihn neben die unterschiedlich
                // breiten Knöpfe)
                ToolbarItem(placement: .principal) {
                    Text(isNew ? tr("Neuer Wecker") : tr("Bearbeiten"))
                        .font(Theme.display(17, weight: .semibold))
                        .foregroundStyle(Theme.moon)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        SmartAlarm.shared.save(item)
                        Haptics.success()
                        dismiss()
                    } label: { Image(systemName: "checkmark") }
                    .accessibilityLabel(tr("Sichern"))
                }
            }
            .onDisappear { SoundPreview.shared.stop() }
            .onChange(of: item.mode) {
                Haptics.select()
                if item.mode == .duration && !hideDurationHint { showDurationHint = true }
            }
            .fullScreenCover(isPresented: $showDurationHint) { DurationHint(hide: $hideDurationHint) }
            .onChange(of: item.snooze) { Haptics.select() }
            .onChange(of: item.smart) { Haptics.select() }
        }
        .tint(Theme.moon)            // Navigation (Abbrechen/Sichern) in Mondweiß
        .preferredColorScheme(.dark)
    }

    private var soundName: String {
        let s = AlarmSound(rawValue: item.sound) ?? .system
        return s == .custom ? (item.customSoundName ?? s.name) : s.name
    }

    private var timePicker: some View {
        DatePicker(tr("Späteste Weckzeit"), selection: Binding(
            get: {
                Calendar.current.date(bySettingHour: item.wakeMinutes / 60, minute: item.wakeMinutes % 60,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                item.wakeMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
    }

    /// 1 min bis 23 h 59 min: das Schlafdauer-Rad der Uhr-App (Timer), mit endlos drehenden Rädern
    private var durationPicker: some View {
        CountdownWheel(minutes: $item.durationMinutes)
            .frame(height: 216)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
    }

    /// Kurzbeschreibung für die Liste
    static func summary(_ a: AlarmItem) -> String {
        var parts: [String] = []
        if !a.label.isEmpty { parts.append(a.label) }
        switch a.mode {
        case .time: parts.append(WeekdayPicker.describe(a.repeatDays))
        case .duration: parts.append(tr("ab Aufnahmebeginn, nur mit Aufnahme"))
        }
        if a.smart { parts.append(tr("leicht ab %d min vorher", a.windowMinutes)) }
        return parts.joined(separator: ", ")
    }
}

/// „Wiederholen“ wie in der Uhr-App: Liste der Wochentage mit Häkchen.
private struct RepeatList: View {
    @Binding var days: [Int]
    var body: some View {
        List {
            ForEach(WeekdayPicker.ordered, id: \.self) { d in
                Button {
                    Haptics.select()
                    if days.contains(d) { days.removeAll { $0 == d } } else { days.append(d) }
                } label: {
                    HStack {
                        Text(tr("Jeden %@", Calendar.current.weekdaySymbols[d - 1]))
                            .foregroundStyle(Theme.moon)
                        Spacer()
                        if days.contains(d) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                }
            }
            .listRowBackground(Theme.raised)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ink.ignoresSafeArea())
        .navigationTitle(tr("Wiederholen"))
    }
}

/// „Ton“: eingebaute Töne, eigener Ton aus der Dateien-App, Lautstärke und sanfter Anstieg.
private struct SoundList: View {
    @Binding var item: AlarmItem
    @ObservedObject private var preview = SoundPreview.shared
    @State private var importing = false
    @State private var importError: String?
    @ObservedObject private var test = AlarmSoundTest.shared

    var body: some View {
        List {
            Section {
                ForEach(AlarmSound.builtIn + [.system]) { s in row(s.name, selected: item.sound == s.rawValue,
                                                                   playable: s != .system) {
                    item.sound = s.rawValue
                } }
                if let name = item.customSoundName {
                    row(name, selected: item.sound == AlarmSound.custom.rawValue, playable: true) {
                        item.sound = AlarmSound.custom.rawValue
                    }
                }
                Button(tr("Eigenen Ton auswählen …")) { importing = true }
                    .foregroundStyle(Theme.moon)
            } footer: {
                if let importError {
                    Text(importError).foregroundStyle(Theme.alert)
                } else {
                    Text(tr("Antippen wählt den Ton, nochmal antippen spielt ihn ab oder hält ihn an."))
                }
            }
            .listRowBackground(Theme.raised)

            if item.sound != AlarmSound.system.rawValue {
                if test.ok == true {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill").foregroundStyle(Theme.mist)
                            Slider(value: $item.volume, in: 0...1, onEditingChanged: { _ in preview.stop() })
                                .tint(Theme.accent)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(Theme.mist)
                        }
                    } header: {
                        ListHeader(tr("Lautstärke"))
                    } footer: {
                        Text(tr("Die Lautstärke wird in den Ton gerechnet. Die Klingellautstärke des iPhones gilt zusätzlich."))
                    }
                    .listRowBackground(Theme.raised)
                } else {
                    Section {
                        if test.scheduled != nil {
                            Text(tr("Sperre jetzt das iPhone: In 30 s klingelt ein Test-Wecker. Hast du eine leise Spieluhr gehört, die weiterspielt?"))
                                .foregroundStyle(Theme.moon)
                            Button(tr("Ja, leise Spieluhr")) { test.answer(true) }
                                .foregroundStyle(Theme.accent)
                            Button(tr("Nein, normaler Weckton")) { test.answer(false) }
                                .foregroundStyle(Theme.accent)
                        } else {
                            Button(tr("Ton-Test starten")) { Task { await test.start() } }
                                .foregroundStyle(Theme.accent)
                        }
                    } header: {
                        ListHeader(tr("Lautstärke"))
                    } footer: {
                        Text(test.ok == false
                             ? tr("Dein iPhone spielt für Wecker nur die eingebauten Töne in voller Lautstärke, eigene Töne werden zum Standardton. Die Lautstärke folgt der Klingellautstärke des iPhones.")
                             : tr("Ob iOS eine eigene Lautstärke und eigene Töne für Wecker zulässt, hängt von der iOS-Version ab. Der Test stellt in 30 s einen Wecker mit einer leisen Spieluhr. Sperre dafür das iPhone: Bei eingeschaltetem Bildschirm spielt iOS Wecker anderer Apps nur kurz an."))
                    }
                    .listRowBackground(Theme.raised)
                }
            } else {
                Section {} footer: {
                    Text(tr("Der iPhone-Standardton folgt der Lautstärke in den Einstellungen. iOS gibt die Töne der Uhr-App nicht für andere Apps frei."))
                }
                .listRowBackground(Theme.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ink.ignoresSafeArea())
        .navigationTitle(tr("Ton"))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                do {
                    item.customSound = try AlarmSoundRenderer.importCustom(url)
                    item.customSoundName = url.deletingPathExtension().lastPathComponent
                    item.sound = AlarmSound.custom.rawValue
                    importError = nil
                } catch {
                    importError = tr("Diese Datei lässt sich nicht als Ton verwenden.")
                }
            case .failure: break
            }
        }
        .onDisappear { preview.stop() }
    }

    /// Erstes Tippen wählt den Ton, jedes weitere Tippen auf den gewählten spielt ihn ab bzw. hält ihn an.
    private func row(_ title: String, selected: Bool, playable: Bool, _ pick: @escaping () -> Void) -> some View {
        let playing = selected && preview.playing
        return Button {
            Haptics.select()
            if selected && playable {
                preview.toggle(item)
            } else {
                preview.stop()
                pick()
            }
        } label: {
            HStack {
                Text(title).foregroundStyle(Theme.moon)
                Spacer()
                if playing {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                } else if selected {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityHint(selected && playable ? (playing ? tr("Anhalten") : tr("Probehören")) : "")
    }
}

/// Wochentage als Kreise zum Antippen, in der Reihenfolge des Kalenders (Montag zuerst in DE).
struct WeekdayPicker: View {
    @Binding var days: [Int]

    static var ordered: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.ordered, id: \.self) { d in
                let on = days.contains(d)
                Button {
                    if on { days.removeAll { $0 == d } } else { days.append(d) }
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[d - 1])
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Circle().fill(on ? Theme.accent : Theme.hairline))
                        .foregroundStyle(on ? Theme.ink : Theme.moon)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[d - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    static func describe(_ days: [Int]) -> String {
        let set = Set(days)
        if set.isEmpty { return tr("Einmal") }
        if set.count == 7 { return tr("Täglich") }
        if set == [2, 3, 4, 5, 6] { return tr("Werktags") }
        if set == [1, 7] { return tr("Am Wochenende") }
        return ordered.filter(set.contains).map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")
    }
}

/// Dauer-Rad wie der Timer der Uhr-App, aber beide Räder drehen endlos (UIPickerView mit
/// vielen Wiederholungen, mittig gestartet). 0 h 1 min bis 23 h 59 min.
struct CountdownWheel: UIViewRepresentable {
    @Binding var minutes: Int
    private static let loops = 200

    func makeUIView(context: Context) -> UIPickerView {
        let p = UIPickerView()
        p.dataSource = context.coordinator
        p.delegate = context.coordinator
        context.coordinator.select(p, minutes: minutes, animated: false)
        return p
    }

    func updateUIView(_ p: UIPickerView, context: Context) {
        context.coordinator.parent = self
        let h = p.selectedRow(inComponent: 0) % 24, m = p.selectedRow(inComponent: 1) % 60
        if h * 60 + m != minutes { context.coordinator.select(p, minutes: minutes, animated: false) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: CountdownWheel
        init(_ parent: CountdownWheel) { self.parent = parent }

        func select(_ p: UIPickerView, minutes: Int, animated: Bool) {
            p.selectRow(24 * (loops / 2) + minutes / 60, inComponent: 0, animated: animated)
            p.selectRow(60 * (loops / 2) + minutes % 60, inComponent: 1, animated: animated)
        }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 2 }
        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent c: Int) -> Int {
            (c == 0 ? 24 : 60) * loops
        }
        func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat { 34 }

        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent c: Int,
                        reusing view: UIView?) -> UIView {
            let label = (view as? UILabel) ?? UILabel()
            let value = c == 0 ? row % 24 : row % 60
            let unit = c == 0 ? tr("Std.") : tr("Min.")
            let text = NSMutableAttributedString(string: "\(value)", attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 23, weight: .regular),
                .foregroundColor: UIColor(Theme.moon)])
            text.append(NSAttributedString(string: "  " + unit, attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: UIColor(Theme.moon)]))
            label.attributedText = text
            label.textAlignment = .center
            return label
        }

        func pickerView(_ p: UIPickerView, didSelectRow row: Int, inComponent c: Int) {
            var h = p.selectedRow(inComponent: 0) % 24, m = p.selectedRow(inComponent: 1) % 60
            if h == 0 && m == 0 {   // mindestens 1 Minute, wie beim Timer
                m = 1
                p.selectRow(60 * (loops / 2) + 1, inComponent: 1, animated: true)
            }
            h = min(h, 23)
            // zurück in die Mitte, damit man nie ans Ende kommt
            select(p, minutes: h * 60 + m, animated: false)
            Task { @MainActor in self.parent.minutes = h * 60 + m }
        }
    }
}

/// Hinweis beim Wechsel auf „Schlafdauer“ (Vollbild), mit Haken zum Ausblenden.
private struct DurationHint: View {
    @Binding var hide: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent)
            Text(tr("Wecker nach Schlafdauer"))
                .font(Theme.display(30))
                .multilineTextAlignment(.center)
            Text(tr("Die Zeit läuft ab Beginn der Nachtaufnahme. Dieser Wecker klingelt nur, wenn eine Aufnahme läuft – ohne Aufnahme klingelt er nicht."))
                .font(.body)
                .foregroundStyle(Theme.mist)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                Haptics.select()
                hide.toggle()
            } label: {
                Label(tr("Nicht mehr anzeigen"), systemImage: hide ? "checkmark.square.fill" : "square")
                    .font(.callout)
                    .foregroundStyle(hide ? Theme.accent : Theme.mist)
            }
            .buttonStyle(.plain)
            Button(tr("Verstanden")) { dismiss() }
                .buttonStyle(MoonButtonStyle())
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .foregroundStyle(Theme.moon)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink.ignoresSafeArea())
    }
}
