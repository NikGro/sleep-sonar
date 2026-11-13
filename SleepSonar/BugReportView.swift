import AlarmKit
import AVFoundation
import HealthKit
import SwiftUI

/// „Fehler melden“: Beschreibung, freiwillige Kontaktangabe und (abwählbar) technische Angaben an den Suya-Server.
/// Keine Aufnahmen, keine Schlafdaten. Die technischen Angaben sind vor dem Senden sichtbar.
struct BugReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var contact = ""
    @State private var includeTech = true
    @State private var sending = false
    @State private var sentNumber: String?
    @State private var error: String?
    @FocusState private var focused: Bool

    @State private var tech: [BugReport.Item] = []
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending }

    var body: some View {
        NavigationStack {
            Group {
                if let sentNumber { sent(sentNumber) } else { form }
            }
            .nightBackground()
            .navigationTitle(tr("Fehler melden"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sentNumber == nil {
                    ToolbarItem(placement: .cancellationAction) { Button(tr("Abbrechen")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if sending { ProgressView() } else {
                            Button(tr("Senden")) { Task { await send() } }.disabled(!canSend)
                        }
                    }
                }
            }
            .alert(tr("Nicht gesendet"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(tr("Erneut versuchen")) { Task { await send() } }
                Button(tr("Abbrechen"), role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
        .tint(Theme.moon)
    }

    private var form: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(tr("Was ist passiert, und was hast du davor gemacht?"))
                            .foregroundStyle(Theme.mist)
                            .padding(.top, 8).padding(.leading, 5)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $text)
                        .focused($focused)
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel(tr("Beschreibung"))
                }
            } header: {
                ListHeader(tr("Beschreibung"))
            }
            .listRowBackground(Theme.raised)

            Section {
                TextField(tr("E-Mail oder anderer Kontakt"), text: $contact)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                ListHeader(tr("Kontakt (freiwillig)"))
            } footer: {
                Text(tr("Nur falls wir nachfragen dürfen. Ohne Kontakt bleibt der Bericht anonym."))
                    .foregroundStyle(Theme.mist)
            }
            .listRowBackground(Theme.raised)

            Section {
                Toggle(tr("Technische Angaben mitsenden"), isOn: $includeTech).tint(Theme.accent)
                if includeTech {
                    ForEach(tech, id: \.label) { item in
                        LabeledContent(item.label, value: item.value)
                            .font(.callout)
                    }
                }
            } footer: {
                Text(tr("Keine Aufnahmen, keine Schlafdaten, keine IP-Adresse. Der Bericht wird nur zur Fehlerbehebung genutzt und spätestens nach zwölf Monaten gelöscht."))
                    .foregroundStyle(Theme.mist)
            }
            .listRowBackground(Theme.raised)
        }
        .scrollContentBackground(.hidden)
        .onAppear { if tech.isEmpty { tech = BugReport.technicalDetails() }; focused = true }
    }

    private func sent(_ number: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 56)).foregroundStyle(Theme.moon)
                .accessibilityHidden(true)
            Text(tr("Danke!")).font(Theme.display(28))
            Text(tr("Dein Bericht ist angekommen."))
                .multilineTextAlignment(.center)
            Text(tr("Nummer: %@", number))
                .font(.callout.monospaced()).foregroundStyle(Theme.mist)
                .textSelection(.enabled)
            Button(tr("Fertig")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send() async {
        sending = true; defer { sending = false }
        switch await BugReport.send(text: text, contact: contact, tech: includeTech ? tech : []) {
        case .success(let number): Haptics.success(); sentNumber = number
        case .failure(let message): Haptics.warning(); error = message
        }
    }
}

enum BugReport {
    struct Item { let key: String; let label: String; let value: String }
    enum Outcome { case success(String), failure(String) }

    @MainActor static func technicalDetails() -> [Item] {
        var items: [Item] = [
            Item(key: "app", label: tr("App"), value: MoreView.version),
            Item(key: "ios", label: "iOS", value: UIDevice.current.systemVersion),
            Item(key: "geraet", label: tr("iPhone-Modell"), value: DonationUploader.deviceModel()),
            Item(key: "sprache", label: tr("Sprache"), value: Locale.preferredLanguages.first ?? "?"),
        ]
        let mic: String
        switch AVAudioApplication.shared.recordPermission {
        case .granted: mic = tr("erlaubt")
        case .denied: mic = tr("abgelehnt")
        default: mic = tr("nicht gefragt")
        }
        items.append(Item(key: "mikrofon", label: tr("Mikrofon"), value: mic))
        if HKHealthStore.isHealthDataAvailable() {
            let h: String
            switch HKHealthStore().authorizationStatus(for: HKCategoryType(.sleepAnalysis)) {
            case .sharingAuthorized: h = tr("erlaubt")
            case .sharingDenied: h = tr("abgelehnt")
            default: h = tr("nicht gefragt")
            }
            items.append(Item(key: "health", label: "Health", value: h))
        }
        if #available(iOS 26.0, *) {
            let a: String
            switch AlarmManager.shared.authorizationState {
            case .authorized: a = tr("erlaubt")
            case .denied: a = tr("abgelehnt")
            default: a = tr("nicht gefragt")
            }
            items.append(Item(key: "wecker", label: tr("Wecker"), value: a))
        }
        let spende: String
        switch DataDonation.shared.state {
        case .granted: spende = tr("zugestimmt")
        case .declined: spende = tr("abgelehnt")
        case .undecided: spende = tr("nicht gefragt")
        }
        items.append(Item(key: "spende", label: tr("Datenspende"), value: spende))
        let nights = (try? FileManager.default.contentsOfDirectory(at: NightStore.nightsFolder, includingPropertiesForKeys: nil))?
            .filter(\.hasDirectoryPath).count ?? 0
        items.append(Item(key: "naechte", label: tr("Nächte"), value: "\(nights)"))
        items.append(Item(key: "absturzprotokolle", label: tr("Absturzprotokolle"), value: "\(CrashLog.list().count)"))
        if let free = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            items.append(Item(key: "speicher_frei", label: tr("Freier Speicher"),
                              value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file)))
        }
        return items
    }

    static func send(text: String, contact: String, tech: [Item]) async -> Outcome {
        var request = URLRequest(url: DonationUploader.server.appendingPathComponent("api/fehler"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": String(text.prefix(8000)),
            "kontakt": String(contact.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
            "technik": Dictionary(uniqueKeysWithValues: tech.map { ($0.key, $0.value) }),
            "absturz": tech.isEmpty ? [] : CrashLog.recent(),   // nur mit „Technische Angaben mitsenden“
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if code == 201, let n = obj?["nummer"] as? String { return .success(n) }
            if code == 429 { return .failure(tr("Gerade wurden zu viele Berichte gesendet. Bitte versuch es später noch einmal.")) }
            return .failure(tr("Der Server hat den Bericht nicht angenommen (Fehler %@).", "\(code)"))
        } catch {
            return .failure(tr("Keine Verbindung zum Server. Bitte prüf das Internet und versuch es noch einmal."))
        }
    }
}
