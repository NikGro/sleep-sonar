import Foundation
import Testing
@testable import Suya

@MainActor
struct AlarmStoreTests {
    private func defaults() -> UserDefaults {
        let name = "suya-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func migratesOldKeysOnce() throws {
        let d = defaults()
        let item = AlarmItem()
        let kit = UUID(), extra = UUID()
        d.set(try JSONEncoder().encode([item]), forKey: "alarm.items")
        d.set([item.id.uuidString: kit.uuidString], forKey: "alarm.kitIDs")
        d.set([item.id.uuidString: [extra.uuidString: 2_000_000_000.0]], forKey: "alarm.extraIDs")
        d.set([item.id.uuidString: 1_900_000_000.0], forKey: "alarm.rang")

        let store = AlarmStore(defaults: d)
        #expect(store.items.map(\.id) == [item.id])
        #expect(store.ledger.mainKit(for: item.id) == kit)
        #expect(store.ledger.kits(of: item.id) == [kit, extra])
        #expect(store.ledger.rang[item.id] == Date(timeIntervalSince1970: 1_900_000_000))
        for k in ["alarm.items", "alarm.kitIDs", "alarm.extraIDs", "alarm.rang"] { #expect(d.object(forKey: k) == nil) }

        // zweiter Start liest den neuen Eintrag
        store.ledger.setMain(UUID(), for: item.id)
        store.save()
        let again = AlarmStore(defaults: d)
        #expect(again.ledger == store.ledger)
        #expect(again.items.map(\.id) == [item.id])
    }

    @Test func emptyStart() {
        let store = AlarmStore(defaults: defaults())
        #expect(store.items.isEmpty)
        #expect(store.ledger == .init())
    }
}
