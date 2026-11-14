import Foundation

/// Buchführung, welche Systemwecker (AlarmKit-IDs) zu welchem Suya-Wecker gehören – als ein Wert,
/// der in einem Stück gespeichert wird. So kann kein Abbruch zwischen mehreren Einträgen verwaiste
/// Systemwecker hinterlassen. Reine Daten, ohne AlarmKit; testbar.
public struct AlarmLedger: Codable, Equatable, Sendable {
    /// Wecker → Systemwecker der Regel (Uhrzeit/Wochentage)
    public private(set) var main: [UUID: UUID] = [:]
    /// Wecker → zusätzliche einmalige Systemwecker → gültig bis (eine Stunde nach dem Klingeln)
    public private(set) var extras: [UUID: [UUID: Date]] = [:]
    /// Wecker, die in dieser Nacht schon früh geklingelt haben → bis wann das gilt
    public var rang: [UUID: Date] = [:]

    public init() {}

    public init(main: [UUID: UUID], extras: [UUID: [UUID: Date]], rang: [UUID: Date]) {
        self.main = main
        self.extras = extras
        self.rang = rang
    }

    /// Gültigkeit eines Zusatzweckers nach seinem Klingeln
    public static let extraGrace: TimeInterval = 3600

    public func mainKit(for item: UUID) -> UUID? { main[item] }

    /// alle Systemwecker eines Weckers
    public func kits(of item: UUID) -> Set<UUID> {
        var out = Set(extras[item]?.keys.map { $0 } ?? [])
        if let m = main[item] { out.insert(m) }
        return out
    }

    /// Neuer Systemwecker für die Regel. Gibt den bisherigen zurück, falls er abbestellt werden muss.
    @discardableResult
    public mutating func setMain(_ kit: UUID, for item: UUID) -> UUID? {
        let old = main[item]
        main[item] = kit
        return old == kit ? nil : old
    }

    @discardableResult
    public mutating func removeMain(for item: UUID) -> UUID? {
        main.removeValue(forKey: item)
    }

    /// Gibt es schon einen Zusatzwecker für genau diesen Zeitpunkt?
    public func hasExtra(for item: UUID, at date: Date) -> Bool {
        (extras[item] ?? [:]).values.contains { abs($0.timeIntervalSince(date) - Self.extraGrace) < 1 }
    }

    public mutating func addExtra(_ kit: UUID, for item: UUID, at date: Date) {
        extras[item, default: [:]][kit] = date.addingTimeInterval(Self.extraGrace)
    }

    /// Zusatzwecker eines Weckers austragen, außer denen in `keeping` (z. B. gerade klingelnd).
    /// Gibt die ausgetragenen zurück (zum Abbestellen).
    public mutating func removeExtras(for item: UUID, keeping: Set<UUID> = []) -> [UUID] {
        guard let mine = extras[item] else { return [] }
        let left = mine.filter { keeping.contains($0.key) }
        extras[item] = left.isEmpty ? nil : left
        return mine.keys.filter { !keeping.contains($0) }
    }

    /// Alles eines Weckers austragen; gibt die Systemwecker zum Abbestellen zurück
    public mutating func removeAll(for item: UUID) -> [UUID] {
        let all = Array(kits(of: item))
        main[item] = nil
        extras[item] = nil
        rang[item] = nil
        return all
    }

    /// Abgelaufene Zusatzwecker und Früh-Weck-Marken vergessen; gibt alle noch gültigen Systemwecker zurück
    public mutating func prune(now: Date) -> Set<UUID> {
        for (item, list) in extras {
            let live = list.filter { $0.value > now }
            extras[item] = live.isEmpty ? nil : live
        }
        rang = rang.filter { $0.value > now }
        var keep = Set(main.values)
        for list in extras.values { keep.formUnion(list.keys) }
        return keep
    }
}
