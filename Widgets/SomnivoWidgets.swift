import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

@main
struct SomnivoWidgets: WidgetBundle {
    var body: some Widget {
        NightLiveActivity()
        if #available(iOS 26.0, *) {
            SnoozeLiveActivity()
        }
    }
}

private let ink = Color(red: 0x12 / 255, green: 0x16 / 255, blue: 0x2B / 255)
private let moon = Color(red: 0xEE / 255, green: 0xE6 / 255, blue: 0xCF / 255)
private let mist = Color(red: 0x93 / 255, green: 0x98 / 255, blue: 0xBD / 255)

struct NightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NightActivityAttributes.self) { ctx in
            // Sperrbildschirm und StandBy
            HStack(spacing: 14) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title2)
                    .foregroundStyle(moon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Somnivo hört zu"))
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(moon)
                    Text(tr("seit %@ Uhr", ctx.attributes.start.formatted(date: .omitted, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(mist)
                }
                Spacer()
                Text(ctx.attributes.start, style: .timer)
                    .font(.system(.title2, design: .serif).monospacedDigit())
                    .foregroundStyle(moon)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
            .padding(16)
            .activityBackgroundTint(ink)
            .activitySystemActionForegroundColor(moon)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "moon.zzz.fill").font(.title2).foregroundStyle(moon)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(ctx.attributes.start, style: .timer)
                        .font(.system(.title3, design: .serif).monospacedDigit())
                        .foregroundStyle(moon)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(tr("Nachtaufnahme läuft"))
                        .font(.caption)
                        .foregroundStyle(mist)
                }
            } compactLeading: {
                Image(systemName: "moon.zzz.fill").foregroundStyle(moon)
            } compactTrailing: {
                Text(ctx.attributes.start, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(moon)
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "moon.zzz.fill").foregroundStyle(moon)
            }
            .keylineTint(moon)
        }
    }
}

/// Anzeige beim Schlummern (AlarmKit-Wecker mit Countdown bis zum nächsten Klingeln).
@available(iOS 26.0, *)
struct SnoozeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<WakeMetadata>.self) { ctx in
            HStack(spacing: 14) {
                Image(systemName: "zzz").font(.title2).foregroundStyle(moon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.attributes.metadata?.label ?? "Somnivo")
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(moon)
                    Text(tr("Schlummern")).font(.caption).foregroundStyle(mist)
                }
                Spacer()
                countdown(ctx.state)
                    .font(.system(.title2, design: .serif).monospacedDigit())
                    .foregroundStyle(moon)
            }
            .padding(16)
            .activityBackgroundTint(ink)
            .activitySystemActionForegroundColor(moon)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "zzz").font(.title2).foregroundStyle(moon)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(ctx.state).monospacedDigit().foregroundStyle(moon)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(ctx.attributes.metadata?.label ?? "Somnivo").font(.caption).foregroundStyle(mist)
                }
            } compactLeading: {
                Image(systemName: "zzz").foregroundStyle(moon)
            } compactTrailing: {
                countdown(ctx.state).monospacedDigit().foregroundStyle(moon).frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "zzz").foregroundStyle(moon)
            }
        }
    }

    @ViewBuilder private func countdown(_ state: AlarmPresentationState) -> some View {
        switch state.mode {
        case .countdown(let c):
            Text(timerInterval: Date.now...c.fireDate, countsDown: true)
                .multilineTextAlignment(.trailing)
        default:
            Text("")
        }
    }
}
