import SwiftUI
import Charts
import FeedingCore

/// Today's running milk total beside yesterday's, on one midnight-to-midnight axis.
/// Yesterday's points are already moved onto today's clock by the caller.
struct MilkTodayChart: View {
    let today: [MilkProgressPoint]
    let yesterday: [MilkProgressPoint]
    let day: ClosedRange<Date>
    let yesterdayByNow: Int

    private var todayLabel: String { L10n.text("Today") }
    private var yesterdayLabel: String { L10n.text("Yesterday") }
    private var yesterdayColor: Color { Palette.secondary.opacity(0.55) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(Array(yesterday.enumerated()), id: \.offset) { _, point in
                    line(point, label: yesterdayLabel)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
                }
                ForEach(Array(today.enumerated()), id: \.offset) { _, point in
                    line(point, label: todayLabel)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                if let now = today.last {
                    PointMark(x: .value(L10n.text("Time"), now.time), y: .value("ml", now.totalML))
                        .foregroundStyle(by: .value(L10n.text("Day"), todayLabel))
                        .symbolSize(50)
                }
            }
            .chartForegroundStyleScale(domain: [todayLabel, yesterdayLabel], range: [Palette.green, yesterdayColor])
            .chartXScale(domain: day)
            .chartYScale(domain: 0...max(100, (today + yesterday).map(\.totalML).max() ?? 0))
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted))).foregroundStyle(Palette.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel().foregroundStyle(Palette.secondary)
                }
            }
            .chartLegend(.hidden)
            .frame(height: 120)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { legend }
                VStack(alignment: .leading, spacing: 6) { legend }
            }.font(.caption).foregroundStyle(Palette.secondary)
        }
        // Charts exposes every segment to VoiceOver; one spoken summary is easier to follow.
        .accessibilityRepresentation {
            Text(L10n.text("Milk through the day"))
                .accessibilityValue(L10n.format("Today so far %d ml. By this time yesterday %d ml.",
                                                today.last?.totalML ?? 0, yesterdayByNow))
        }
        .accessibilityIdentifier("milk-today-chart")
    }

    private func line(_ point: MilkProgressPoint, label: String) -> some ChartContent {
        LineMark(x: .value(L10n.text("Time"), point.time), y: .value("ml", point.totalML),
                 series: .value(L10n.text("Day"), label))
            .interpolationMethod(.stepEnd)
            .foregroundStyle(by: .value(L10n.text("Day"), label))
    }

    @ViewBuilder private var legend: some View {
        legendItem(todayLabel, color: Palette.green, dash: [])
        legendItem(yesterdayLabel, color: yesterdayColor, dash: [4, 4])
    }

    private func legendItem(_ title: String, color: Color, dash: [CGFloat]) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1.5)); path.addLine(to: CGPoint(x: 16, y: 1.5))
            }.stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: dash))
                .frame(width: 16, height: 3)
            Text(title).fixedSize()
        }
    }
}
