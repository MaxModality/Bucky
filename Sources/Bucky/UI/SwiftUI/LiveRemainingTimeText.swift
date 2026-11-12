import SwiftUI

// Visible rows own the clock. Recurrence is derived from the anchor, never saved on each tick.
@available(macOS 26.0, *)
struct LiveRemainingTimeText: View {
    let target: Date
    var recurrence: CountdownRecurrence = .none
    var timeZoneIdentifier: String?
    @State private var isVisible = false
    @State private var isComplete = false
    @State private var nextTarget: Date?

    private func nextDate(after now: Date) -> Date? {
        Countdown(name: "", targetDate: target, recurrence: recurrence,
                  timeZoneIdentifier: timeZoneIdentifier ?? TimeZone.current.identifier)
            .nextTargetDate(after: now)
    }

    private func refresh(at now: Date) {
        nextTarget = nextDate(after: now)
        isComplete = nextTarget == nil
    }

    var body: some View {
        Group {
            if isComplete {
                Text(CountdownRemaining.zero.displayString)
            } else {
                TimelineView(.animation(minimumInterval: Double(CountdownStone.refreshIntervalNanoseconds) / 1_000_000_000,
                                        paused: !isVisible)) { context in
                    let date = nextTarget ?? target
                    Text(CountdownRemaining(until: date, now: context.date).displayString)
                        .onChange(of: context.date >= date) { _, reached in
                            if reached { refresh(at: context.date) }
                        }
                }
            }
        }
        .monospacedDigit()
        .transaction { $0.animation = nil }
        .onAppear { refresh(at: Date()); isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: target) { _, _ in refresh(at: Date()) }
        .onChange(of: recurrence) { _, _ in refresh(at: Date()) }
        .onChange(of: timeZoneIdentifier) { _, _ in refresh(at: Date()) }
    }
}
