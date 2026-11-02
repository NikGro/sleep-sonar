import SwiftUI

/// Vollbild, solange Suya während der Nachtaufnahme selbst klingelt.
struct RingingView: View {
    @ObservedObject private var ringer = AlarmRinger.shared

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "sun.horizon.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse)
            TimelineView(.everyMinute) { ctx in
                Text(ctx.date, style: .time)
            }
                .font(.system(size: 64, weight: .regular, design: .serif).monospacedDigit())
                .foregroundStyle(Theme.moon)
            Text(ringer.title)
                .font(.system(.title3, design: .serif))
                .foregroundStyle(Theme.mist)
            Spacer()
            if ringer.canSnooze {
                Button {
                    Haptics.tap()
                    SmartAlarm.shared.snoozeRinging()
                } label: {
                    Label(tr("Schlummern"), systemImage: "zzz")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }
            Button {
                Haptics.tap()
                SmartAlarm.shared.stopRinging()
            } label: {
                Label(tr("Aus"), systemImage: "sun.max")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.moon)
            .foregroundStyle(Theme.ink)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
