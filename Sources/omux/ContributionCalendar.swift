import SwiftUI

/// The last year as GitHub draws contributions: a column for each week, a square for each day,
/// in four greens by the hours worked (or tokens used) that day. Clicking a day shows it on the
/// whole page.
struct ContributionCalendar: View {
    @ObservedObject var model: StatsModel
    @AppStorage("statsCalendarMetric") private var metric = Metric.time
    @Environment(\.colorScheme) private var scheme
    @State private var hover: Date?
    /// The width there is for the grid; the page measures it.
    let width: CGFloat

    enum Metric: String, CaseIterable {
        case time = "Time", tokens = "Tokens"
    }

    static let weeks = 53
    private var labelWidth: CGFloat { Self.labelWidth }
    private var monthRow: CGFloat { Self.monthRow }

    /// The width of a week's column: GitHub's squares, grown to fill wide windows.
    private var step: CGFloat { min(24, max(8, ((width - labelWidth) / CGFloat(Self.weeks)).rounded(.down))) }

    private var empty: Color { Self.empty(scheme) }
    private var greens: [Color] { Self.greens(scheme) }
    static func empty(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.09, green: 0.11, blue: 0.13) : Color(red: 0.92, green: 0.93, blue: 0.94)
    }
    static func greens(_ scheme: ColorScheme) -> [Color] {
        scheme == .dark
            ? [Color(red: 0.05, green: 0.27, blue: 0.16), Color(red: 0.0, green: 0.43, blue: 0.2), Color(red: 0.15, green: 0.65, blue: 0.25), Color(red: 0.22, green: 0.83, blue: 0.33)]
            : [Color(red: 0.61, green: 0.91, blue: 0.66), Color(red: 0.25, green: 0.77, blue: 0.39), Color(red: 0.19, green: 0.63, blue: 0.31), Color(red: 0.13, green: 0.43, blue: 0.22)]
    }

    var body: some View {
        let days = Self.days()
        let values = days.map { value(model.year[$0]) }
        let thresholds = Self.quartiles(values)
        VStack(alignment: .leading, spacing: 10) {
            header(values: values)
            grid(days: days, values: values, thresholds: thresholds)
                .frame(width: labelWidth + step * CGFloat(Self.weeks), height: monthRow + step * 7)
                .frame(maxWidth: .infinity)
            footer
        }
        .padding(16)
    }

    private func value(_ total: StatsDayTotal?) -> Double {
        guard let total else { return 0 }
        return metric == .time ? total.time : Double(total.tokens)
    }

    private func describe(_ value: Double) -> String {
        metric == .time ? (value < 60 ? "No work" : StatsStyle.duration(value)) : (value == 0 ? "No tokens" : "\(StatsStyle.tokens(Int(value))) tokens")
    }

    private func header(values: [Double]) -> some View {
        let total = values.reduce(0, +)
        return HStack(spacing: 10) {
            Text(metric == .time ? "\(StatsStyle.hours(total)) hours in the last year" : "\(StatsStyle.tokens(Int(total))) tokens in the last year")
                .font(.system(size: 13, weight: .semibold))
            if let id = model.selectedProjectID, let project = model.snapshot.project(id) {
                HStack(spacing: 5) {
                    Circle().fill(project.color).frame(width: 7, height: 7)
                    Text(project.name).font(.system(size: 11.5, weight: .medium))
                }
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(project.color.opacity(0.14), in: Capsule())
            }
            Spacer(minLength: 8)
            Picker("", selection: $metric) {
                ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var footer: some View {
        HStack(spacing: 3) {
            Group {
                if let hover {
                    Text("\(describe(value(model.year[hover]))) on \(hover.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))")
                } else {
                    Text("Click a day to see it on the page")
                }
            }
            .lineLimit(1)
            .foregroundStyle(StatsStyle.muted)
            Spacer(minLength: 8)
            Text("Less").padding(.trailing, 3)
            RoundedRectangle(cornerRadius: 2).fill(empty).frame(width: 10, height: 10)
            ForEach(0..<4, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(greens[$0]).frame(width: 10, height: 10) }
            Text("More").padding(.leading, 3)
        }
        .font(.system(size: 11))
        .foregroundStyle(StatsStyle.faint)
    }

    private func grid(days: [Date], values: [Double], thresholds: [Double]) -> some View {
        let step = step, scheme = scheme
        let selected = model.day
        let hover = hover
        return Canvas { context, _ in
            Self.draw(in: &context, days: days, values: values, thresholds: thresholds, step: step, scheme: scheme,
                      selected: selected, hover: hover)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): self.hover = self.day(at: point, days: days)
            case .ended: self.hover = nil
            }
        }
        .onTapGesture { point in
            guard let day = self.day(at: point, days: days) else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                if model.day == day { model.day = nil; return }
                if !model.covers(day) { model.range = .month(StatsModel.startOfMonth(day)) }
                model.day = day
            }
        }
    }

    static let labelWidth: CGFloat = 30
    static let monthRow: CGFloat = 18

    /// The grid's size for a week column `step` wide.
    static func size(step: CGFloat) -> CGSize { CGSize(width: labelWidth + step * CGFloat(weeks), height: monthRow + step * 7) }

    /// The squares, their months and weekdays.
    static func draw(in context: inout GraphicsContext, days: [Date], values: [Double], thresholds: [Double], step: CGFloat,
                     scheme: ColorScheme, selected: Date? = nil, hover: Date? = nil) {
        let calendar = Calendar.current
        let gap: CGFloat = 3, labelWidth = labelWidth, monthRow = monthRow
        let empty = empty(scheme), greens = greens(scheme)
        let today = calendar.startOfDay(for: Date())
        do {
            let side = step - gap
            // Weekday names on every other row, as GitHub does.
            for row in [1, 3, 5] {
                let weekday = (calendar.firstWeekday - 1 + row) % 7
                context.draw(Text(calendar.shortWeekdaySymbols[weekday]).font(.system(size: 9.5)).foregroundColor(StatsStyle.faint),
                             at: CGPoint(x: 0, y: monthRow + CGFloat(row) * step + side / 2), anchor: .leading)
            }
            var lastMonth = -1
            for (i, day) in days.enumerated() {
                let column = i / 7, row = i % 7
                let x = labelWidth + CGFloat(column) * step
                let y = monthRow + CGFloat(row) * step
                if row == 0 {
                    let monthIndex = calendar.component(.month, from: day)
                    if monthIndex != lastMonth, column < Self.weeks - 1 {
                        if lastMonth != -1 || calendar.component(.day, from: day) <= 7 {
                            context.draw(Text(calendar.shortMonthSymbols[monthIndex - 1]).font(.system(size: 9.5)).foregroundColor(StatsStyle.muted),
                                         at: CGPoint(x: x, y: 2), anchor: .topLeading)
                        }
                        lastMonth = monthIndex
                    }
                }
                guard day <= today else { continue }
                let rect = CGRect(x: x, y: y, width: side, height: side)
                let shape = Path(roundedRect: rect, cornerRadius: max(2, side / 5))
                let level = Self.level(values[i], thresholds)
                context.fill(shape, with: .color(level.map { greens[$0] } ?? empty))
                if day == selected {
                    context.stroke(shape, with: .color(StatsStyle.ink), lineWidth: 1.5)
                } else if day == hover {
                    context.stroke(shape, with: .color(StatsStyle.ink.opacity(0.55)), lineWidth: 1)
                } else if day == today {
                    context.stroke(shape, with: .color(StatsStyle.accent.opacity(0.8)), lineWidth: 1)
                }
            }
        }
    }

    private func day(at point: CGPoint, days: [Date]) -> Date? {
        guard point.x >= labelWidth, point.y >= monthRow else { return nil }
        let column = Int((point.x - labelWidth) / step), row = Int((point.y - monthRow) / step)
        guard row < 7, column < Self.weeks else { return nil }
        let index = column * 7 + row
        guard days.indices.contains(index), days[index] <= Date() else { return nil }
        return days[index]
    }

    /// The 53 weeks' days, column by column.
    static func days() -> [Date] {
        let calendar = Calendar.current
        let start = StatsModel.yearStart
        return (0..<(weeks * 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Where the four greens begin, as GitHub splits them: by quarters of the days with any.
    static func quartiles(_ values: [Double]) -> [Double] {
        let worked = values.filter { $0 > 0 }.sorted()
        guard !worked.isEmpty else { return [0, 0, 0] }
        return [0.25, 0.5, 0.75].map { worked[min(worked.count - 1, Int(Double(worked.count) * $0))] }
    }

    static func level(_ value: Double, _ thresholds: [Double]) -> Int? {
        guard value > 0 else { return nil }
        return thresholds.filter { value >= $0 }.count.clamped(to: 0...3)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
