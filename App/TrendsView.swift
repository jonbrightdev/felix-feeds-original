import SwiftUI
import Charts
import FeedingCore

struct TrendsView: View {
    @Environment(FeedingStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var dayCount = 7
    @State private var selectedDate: Date?

    private let bottleColors: [Color] = [Color(hex: 0x588C7D), Color(hex: 0xB47745), Color(hex: 0x6686AE)]
    private let breastColors: [Color] = [Color(hex: 0x6686AE), Color(hex: 0xB16F86)]

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(now: context.date)
            }
            .background(Palette.background)
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private func content(now: Date) -> some View {
        let days = store.ledger.feedingDays(count: dayCount, endingAt: now)
        let chosen = days.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDate ?? now) } ?? days.last!
        let end = Calendar.current.date(byAdding: .day, value: 1, to: days.last!.date)!
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    if !typeSize.isAccessibilitySize {
                        BabyIllustration(pose: .resting, width: 70, animated: false)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("A little rhythm").font(.title2.bold())
                        Text("See how your days unfold.")
                            .font(.subheadline).foregroundStyle(Palette.secondary)
                    }
                }
                Picker("Time range", selection: $dayCount) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                }.pickerStyle(.segmented)

                if !days.contains(where: \.hasRecords) {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(Palette.green)
                        Text("Your rhythm starts here").font(.headline)
                        Text("Log a feed or hunger signs to see them here. Days without entries mean nothing was logged.")
                            .font(.subheadline).foregroundStyle(Palette.secondary)
                    }
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .padding(24).background(Palette.card, in: RoundedRectangle(cornerRadius: 26))
                } else {
                    daySelector(chosen, days: days)
                    bottleChart(days, selected: chosen, end: end)
                    breastChart(days, selected: chosen, end: end)
                    rhythmChart(chosen, now: now)
                    dailyTotals(days)
                }
                Text("Completed feeds only, grouped by local start date. Today is still in progress. Days without entries mean nothing was logged.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
            .padding(20).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }
    }

    private func daySelector(_ day: FeedingDay, days: [FeedingDay]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { moveDay(-1, from: day, in: days) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }.disabled(day.id == days.first?.id).accessibilityLabel("Previous day")
                Spacer(minLength: 0)
                VStack(spacing: 3) {
                    Text(day.date, format: .dateTime.weekday(.wide).day().month(.abbreviated))
                        .font(.headline).multilineTextAlignment(.center)
                    if Calendar.current.isDateInToday(day.date) {
                        Text("Today so far").font(.caption).foregroundStyle(Palette.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button { moveDay(1, from: day, in: days) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44)
                }.disabled(day.id == days.last?.id).accessibilityLabel("Next day")
            }
            Text(L10n.format("Feeds: %d · Hunger signs: %d", day.feedCount, day.hungerCueCount))
                .font(.subheadline).foregroundStyle(Palette.secondary)
            Text("Touch a chart to explore a day.").font(.caption).foregroundStyle(Palette.secondary)
        }.padding(16).background(Palette.sage, in: RoundedRectangle(cornerRadius: 24))
    }

    private func moveDay(_ offset: Int, from day: FeedingDay, in days: [FeedingDay]) {
        guard let index = days.firstIndex(where: { $0.id == day.id }), days.indices.contains(index + offset) else { return }
        selectedDate = days[index + offset].date
    }

    private func bottleChart(_ days: [FeedingDay], selected: FeedingDay, end: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            chartHeading("Milk intake", value: L10n.format("%d ml", selected.volume.totalML), icon: "drop.fill")
            Text(selected.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.caption).foregroundStyle(Palette.secondary)
            Text("Bottle amounts and estimated milk at breast").font(.subheadline).foregroundStyle(Palette.secondary)
            Chart {
                ForEach(days) { day in
                    BarMark(x: .value(L10n.text("Day"), day.date, unit: .day),
                            y: .value("ml", day.volume.expressedML))
                        .foregroundStyle(by: .value(L10n.text("Type"), FeedKind.expressed.title))
                        .accessibilityLabel(Text(day.date, format: .dateTime.day().month()))
                        .accessibilityValue(L10n.format("Expressed milk: %d ml", day.volume.expressedML))
                    BarMark(x: .value(L10n.text("Day"), day.date, unit: .day),
                            y: .value("ml", day.volume.formulaML))
                        .foregroundStyle(by: .value(L10n.text("Type"), FeedKind.formula.title))
                        .accessibilityLabel(Text(day.date, format: .dateTime.day().month()))
                        .accessibilityValue(L10n.format("Formula: %d ml", day.volume.formulaML))
                    BarMark(x: .value(L10n.text("Day"), day.date, unit: .day),
                            y: .value("ml", day.volume.estimatedBreastML))
                        .foregroundStyle(by: .value(L10n.text("Type"), L10n.text("Estimated at breast")))
                        .accessibilityLabel(Text(day.date, format: .dateTime.day().month()))
                        .accessibilityValue(L10n.format("Estimated milk: %d ml", day.volume.estimatedBreastML))
                }
                selectedRule(selected)
            }
            .chartForegroundStyleScale(domain: [FeedKind.expressed.title, FeedKind.formula.title, L10n.text("Estimated at breast")], range: bottleColors)
            .chartXScale(domain: days.first!.date...end)
            .chartYScale(domain: 0...max(100, days.map(\.volume.totalML).max() ?? 0))
            .chartXSelection(value: $selectedDate)
            .chartGesture { proxy in
                SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) }
            }
            .chartXAxis { dayAxis }
            .chartLegend(.hidden)
            .frame(height: 180)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityLabel("Daily milk intake")
            legend([FeedKind.expressed.title, FeedKind.formula.title, L10n.text("Estimated at breast")], colors: bottleColors)
            Text("Includes parent-entered breastfeeding estimates. Time alone does not add milk volume.").font(.caption).foregroundStyle(Palette.secondary)
        }.chartCard()
    }

    private func breastChart(_ days: [FeedingDay], selected: FeedingDay, end: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            chartHeading("Breastfeeding", value: TimeText.duration(selected.breastSeconds), icon: "heart.fill")
            Text(selected.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.caption).foregroundStyle(Palette.secondary)
            Text("Recorded time at breast").font(.subheadline).foregroundStyle(Palette.secondary)
            Chart {
                ForEach(days) { day in
                    BarMark(x: .value(L10n.text("Day"), day.date, unit: .day),
                            y: .value(L10n.text("Minutes"), day.breastSeconds / 60))
                        .foregroundStyle(breastColors[0])
                        .accessibilityLabel(Text(day.date, format: .dateTime.day().month()))
                        .accessibilityValue(TimeText.duration(day.breastSeconds))
                }
                selectedRule(selected)
            }
            .chartXScale(domain: days.first!.date...end)
            .chartYScale(domain: 0...max(10, (days.map(\.breastSeconds).max() ?? 0) / 60))
            .chartXSelection(value: $selectedDate)
            .chartGesture { proxy in
                SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) }
            }
            .chartXAxis { dayAxis }
            .chartLegend(.hidden)
            .frame(height: 180)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityLabel("Daily breastfeeding minutes")
            Text("Total time at breast; pauses are excluded.").font(.caption).foregroundStyle(Palette.secondary)
        }.chartCard()
    }

    private var dayAxis: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: dayCount == 7 ? 1 : 2)) { _ in
            AxisValueLabel(format: .dateTime.day())
        }
    }

    @ChartContentBuilder private func selectedRule(_ day: FeedingDay) -> some ChartContent {
        // Midpoint uses the actual local day length, including clock changes.
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day.date)!
        RuleMark(x: .value(L10n.text("Day"), day.date.addingTimeInterval(next.timeIntervalSince(day.date) / 2)))
            .foregroundStyle(Palette.secondary.opacity(0.6))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .accessibilityHidden(true)
    }

    private func rhythmChart(_ day: FeedingDay, now: Date) -> some View {
        let entries = store.ledger.history(on: day.date).filter { entry in
            if case .feed(let feed) = entry { return feed.endedAt <= now }
            if case .pump = entry { return false }
            return entry.date <= now
        }
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day.date)!
        let labels = [FeedKind.breast.title, FeedKind.expressed.title, FeedKind.formula.title, L10n.text("Hunger signs")]
        return VStack(alignment: .leading, spacing: 14) {
            Text("The day's rhythm").font(.title3.bold())
            Text(day.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.caption).foregroundStyle(Palette.secondary)
            Text("Each symbol marks a logged start or observation.").font(.subheadline).foregroundStyle(Palette.secondary)
            if entries.isEmpty {
                Text("Nothing logged on this day.").font(.subheadline).padding(.vertical, 20)
            } else {
                Chart(entries) { entry in
                    PointMark(x: .value(L10n.text("Time"), entry.date),
                              y: .value(L10n.text("Type"), category(entry)))
                        .foregroundStyle(by: .value(L10n.text("Type"), category(entry)))
                        .symbol(by: .value(L10n.text("Type"), category(entry)))
                        .symbolSize(65)
                        .accessibilityLabel(category(entry))
                        .accessibilityValue(Text(entry.date, format: .dateTime.hour().minute()))
                }
                .chartXScale(domain: day.date...next)
                .chartYScale(domain: labels)
                .chartForegroundStyleScale(domain: labels, range: [breastColors[0], bottleColors[0], bottleColors[1], breastColors[1]])
                .chartSymbolScale(domain: labels, range: [.circle, .square, .triangle, .diamond])
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel { Text(value.as(String.self) ?? "").font(.caption2) }
                        AxisGridLine()
                    }
                }
                .chartLegend(.hidden)
                .frame(height: typeSize.isAccessibilitySize ? 260 : 180)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityLabel("Feed and hunger timeline")
            }
            Text("Local time · Hunger signs are observations, not feeds.").font(.caption).foregroundStyle(Palette.secondary)
        }.chartCard()
    }

    private func category(_ entry: HistoryEntry) -> String {
        switch entry {
        case .feed(let feed): feed.kind.title
        case .hunger: L10n.text("Hunger signs")
        case .pump: L10n.text("Pumping")
        }
    }

    private func dailyTotals(_ days: [FeedingDay]) -> some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                ForEach(days.reversed()) { day in
                    Button { selectedDate = day.date } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(day.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated)).font(.headline)
                            Text(L10n.format("Feeds: %d · Hunger signs: %d", day.feedCount, day.hungerCueCount))
                            Text(L10n.format("Expressed milk: %d ml", day.volume.expressedML))
                            Text(L10n.format("Formula: %d ml", day.volume.formulaML))
                            Text(L10n.format("Estimated milk: %d ml", day.volume.estimatedBreastML))
                            Text(L10n.format("Total milk intake: %d ml", day.volume.totalML))
                            Text(L10n.text("Breastfeeding") + ": " + TimeText.duration(day.breastSeconds))
                        }.font(.subheadline).foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                    }.buttonStyle(.plain).accessibilityElement(children: .combine)
                    if day.id != days.first?.id { Divider() }
                }
            }
        } label: { Text("Daily totals").font(.headline).foregroundStyle(Palette.ink) }
        .chartCard()
    }

    private func chartHeading(_ title: LocalizedStringKey, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(value).font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
        }
    }

    private func legend(_ labels: [String], colors: [Color]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { legendItems(labels, colors: colors) }
            VStack(alignment: .leading, spacing: 8) { legendItems(labels, colors: colors) }
        }
    }

    @ViewBuilder private func legendItems(_ labels: [String], colors: [Color]) -> some View {
        ForEach(labels.indices, id: \.self) { index in
            HStack(spacing: 6) {
                Circle().fill(colors[index]).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(labels[index]).font(.caption).foregroundStyle(Palette.secondary)
            }
        }
    }
}

private extension View {
    func chartCard() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 26))
    }
}
