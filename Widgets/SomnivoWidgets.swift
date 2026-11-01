import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SomnivoWidgets: WidgetBundle {
    var body: some Widget {
        NightLiveActivity()
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
