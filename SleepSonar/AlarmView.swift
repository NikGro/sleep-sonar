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
            .navigationTitle(isNew ? tr("Wecker hinzufügen") : tr("Wecker bearbeiten"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Abbrechen")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Sichern")) {
                        SmartAlarm.shared.save(item)
                        Haptics.success()
                        dismiss()
                    }
                }
            }
            .onDisappear { SoundPreview.shared.stop() }
            .onChange(of: item.mode) { Haptics.select() }
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
        case .duration: parts.append(tr("Schlafdauer"))
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
    private let ramps = [0, 10, 30, 60, 120, 180, 300]

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
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill").foregroundStyle(Theme.mist)
                        Slider(value: $item.volume, in: 0...1, onEditingChanged: { _ in preview.stop() })
                            .tint(Theme.accent)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(Theme.mist)
                    }
                    Picker(tr("Lauter werden"), selection: $item.rampSeconds) {
                        ForEach(ramps, id: \.self) { r in
                            Text(r == 0 ? tr("Sofort") : r < 60 ? tr("in %d s", r) : tr("in %d min", r / 60)).tag(r)
                        }
                    }
                } header: {
                    ListHeader(tr("Lautstärke"))
                } footer: {
                    Text(tr("Lautstärke und Lauterwerden gelten, solange die Nachtaufnahme läuft: Dann spielt Suya den Ton selbst, mit der Medienlautstärke des iPhones. Zur Sicherheit klingelt 2 Minuten später der normale Wecker, falls Suya nicht mehr läuft. Ohne Aufnahme klingelt der Ton in voller Lautstärke."))
                }
                .listRowBackground(Theme.raised)
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
