import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

@main
struct SuyaWidgets: WidgetBundle {
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
            VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title2)
                    .foregroundStyle(moon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Suya hört zu"))
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
            if ctx.state.sounds != nil { SoundsRow(state: ctx.state) }
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
                    if ctx.state.sounds != nil {
                        SoundsRow(state: ctx.state)
                    } else {
                        Text(tr("Nachtaufnahme läuft"))
                            .font(.caption)
                            .foregroundStyle(mist)
                    }
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
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "zzz").font(.title2).foregroundStyle(moon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ctx.attributes.metadata?.label ?? "Suya")
                            .font(.system(.headline, design: .serif))
                            .foregroundStyle(moon)
                        Text(tr("Schlummern")).font(.caption).foregroundStyle(mist)
                    }
                    Spacer()
                    countdown(ctx.state)
                        .font(.system(.title2, design: .serif).monospacedDigit())
                        .foregroundStyle(moon)
                }
                stopButton(ctx.state)
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
                    HStack {
                        Text(ctx.attributes.metadata?.label ?? "Suya").font(.caption).foregroundStyle(mist)
                        Spacer()
                        stopButton(ctx.state)
                    }
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

    @ViewBuilder private func stopButton(_ state: AlarmPresentationState) -> some View {
        if case .countdown = state.mode {
            Button(intent: StopSnoozeIntent(alarmID: state.alarmID)) {
                Label(tr("Schlummern beenden"), systemImage: "sun.max").font(.caption.weight(.semibold))
            }
            .tint(accent)
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

private let accent = Color(red: 0xC5 / 255, green: 0x9B / 255, blue: 0xFF / 255)

/// Schlafklänge mit Abspielen/Ausblenden; während des Ausblendens füllt sich ein Balken.
struct SoundsRow: View {
    let state: NightActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.playing ? "speaker.wave.2.fill" : "speaker.fill")
                .foregroundStyle(state.playing ? accent : mist)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.sounds ?? "").font(.caption).foregroundStyle(moon).lineLimit(1)
                if let a = state.fadeStart, let b = state.fadeEnd, b > a {
                    ProgressView(timerInterval: a...b, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .progressViewStyle(.linear)
                        .tint(accent)
                }
            }
            Spacer(minLength: 8)
            if state.playing {
                if state.fadeStart == nil {
                    Button(intent: FadeSoundsIntent()) {
                        Label(tr("Ausblenden"), systemImage: "pause.fill").font(.caption.weight(.semibold))
                    }
                    .tint(accent)
                } else {
                    Button(intent: StopSoundsIntent()) {
                        Label(tr("Sofort aus"), systemImage: "stop.fill").font(.caption.weight(.semibold))
                    }
                    .tint(accent)
                }
            } else {
                Button(intent: PlaySoundsIntent()) {
                    Label(tr("Abspielen"), systemImage: "play.fill").font(.caption.weight(.semibold))
                }
                .tint(accent)
            }
        }
    }
}
