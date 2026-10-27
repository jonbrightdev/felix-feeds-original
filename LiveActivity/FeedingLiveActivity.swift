import ActivityKit
import SwiftUI
import WidgetKit
import FeedingCore

@main struct FeedingWidgets: WidgetBundle {
    var body: some Widget { FeedingLiveActivity() }
}

struct FeedingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FeedingActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L10n.text(title(context.state), locale: displayLocale(context.state)), systemImage: "heart.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(context.state.startedAt, format: .dateTime.hour().minute())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                        .accessibilityLabel(L10n.text("Time since feed started", locale: displayLocale(context.state)))
                    Spacer(minLength: 8)
                    Text(context.state.detail).font(.subheadline)
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2)
                }
                Text(L10n.text("Since feed started", locale: displayLocale(context.state))).font(.caption).foregroundStyle(.secondary)
            }
            .environment(\.locale, displayLocale(context.state))
            .padding(16)
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .activitySystemActionForegroundColor(Color.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(L10n.text(title(context.state), locale: displayLocale(context.state)), systemImage: "heart.fill")
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.title3.monospacedDigit()).minimumScaleFactor(0.6).lineLimit(1)
                        .frame(width: 96, alignment: .trailing)
                        .accessibilityLabel(L10n.text("Time since feed started", locale: displayLocale(context.state)))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.detail)
                        Spacer()
                        Text(L10n.format("Started %@", context.state.startedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(displayLocale(context.state))), locale: displayLocale(context.state)))
                    }.font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "heart.fill").foregroundStyle(.mint)
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityLabel(L10n.text("Feeding timer", locale: displayLocale(context.state)))
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    // Timer text otherwise asks for spare width as its digits grow.
                    // Keep the island small while allowing h:mm:ss to count live.
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityLabel(L10n.text("Time since feed started", locale: displayLocale(context.state)))
            } minimal: {
                Image(systemName: "heart.fill").foregroundStyle(.mint)
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityLabel(L10n.text("Feeding timer", locale: displayLocale(context.state)))
            }
            .keylineTint(.mint)
        }
    }

    private func displayLocale(_ state: FeedingActivityAttributes.ContentState) -> Locale {
        Locale(identifier: state.languageCode ?? L10n.languageCode)
    }

    private func title(_ state: FeedingActivityAttributes.ContentState) -> String {
        if state.isFeeding { return state.isPaused ? "Feed paused" : "Feeding now" }
        return "Last feed"
    }
}
