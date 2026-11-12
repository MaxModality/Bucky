import Foundation

@MainActor
final class CountdownStone: InlineCreationStoneProvider {
    static let refreshIntervalNanoseconds: UInt64 = 50_000_000

    private let store: CountdownStore
    private let now: () -> Date
    private let countdownsDidChange: @MainActor ([Countdown]) -> Void

    init(
        store: CountdownStore,
        now: @escaping () -> Date = Date.init,
        countdownsDidChange: @escaping @MainActor ([Countdown]) -> Void = { _ in }
    ) {
        self.store = store
        self.now = now
        self.countdownsDidChange = countdownsDidChange
    }

    var definition: StoneDefinition {
        StoneDefinition(
            id: .countdowns,
            shortcutNumber: 5,
            presentation: StonePresentation(
                title: "Countdowns",
                placeholder: "Manage Countdowns",
                systemImage: "timer"
            ),
            surface: .sharedResults,
            updatePolicy: .immediate,
            tint: StoneTint(
                activeHex: 0x34C759,
                panelHex: 0x1E7A3A,
                iconHex: 0x0B5D2A,
                darkModeIconHex: 0x8FF0A8
            ),
            animatesResultUpdates: false
        )
    }

    var inlineCreationConfiguration: StoneInlineCreationConfiguration {
        StoneInlineCreationConfiguration(
            namePlaceholder: "Countdown name",
            targetDateLabel: "Target date and time",
            submitHelp: "Add countdown",
            systemImage: "timer",
            defaultTargetDate: now().addingTimeInterval(3_600),
            options: CountdownRecurrence.allCases.map {
                StoneInlineCreationOption(id: $0.rawValue, title: $0.title, help: Self.help(for: $0))
            }
        )
    }

    func snapshot(for query: String) -> StoneResultSnapshot {
        .loaded(rows: Self.rows(for: store.countdowns, now: now()))
    }

    func updateSnapshot(for query: String) async -> StoneResultSnapshot {
        snapshot(for: query)
    }

    func cancel() {}

    func activation(for row: StoneResultRow) -> StoneActivation {
        row.primaryActivation
    }

    func submitInlineCreation(name: String, targetDate: Date) -> Bool {
        guard targetDate > now(), store.add(name: name, targetDate: targetDate) != nil else {
            return false
        }
        countdownsDidChange(store.countdowns)
        return true
    }

    var inlineCreationError: String? { store.lastError }

    func submitInlineCreationAsync(name: String, targetDate: Date) async -> Bool {
        await submitInlineCreationAsync(name: name, targetDate: targetDate, optionID: nil)
    }

    func submitInlineCreationAsync(name: String, targetDate: Date, optionID: String?) async -> Bool {
        guard targetDate > now(),
              let recurrence = CountdownRecurrence(rawValue: optionID ?? CountdownRecurrence.none.rawValue),
              await store.addAsync(name: name, targetDate: targetDate, recurrence: recurrence) != nil else {
            return false
        }
        countdownsDidChange(store.countdowns)
        return true
    }

    func performAsync(_ activation: StoneActivation, for row: StoneResultRow) async -> StoneProviderActivationResult {
        if case let .providerAction(action) = activation, action.hasPrefix("repeat:") {
            let parts = action.split(separator: ":")
            guard parts.count == 3, let id = UUID(uuidString: String(parts[1])),
                  row.id == .tool(kind: .message, key: "countdown:\(id.uuidString)"),
                  let recurrence = CountdownRecurrence(rawValue: String(parts[2])) else { return .unhandled }
            guard await store.updateAsync(id: id, recurrence: recurrence, now: now()) else {
                return .failed(message: store.lastError ?? "Could not change the repeat schedule.")
            }
            countdownsDidChange(store.countdowns)
            return .handled(shouldRefresh: true, resetSelection: false, shouldHide: false)
        }
        if case let .providerAction(action) = activation,
           let id = id(from: action, prefix: "delete-confirm:") {
            guard await store.removeAsync(id: id) else {
                return .failed(message: store.lastError ?? "Could not delete this countdown.")
            }
            countdownsDidChange(store.countdowns)
            return .handled(shouldRefresh: true, resetSelection: true, shouldHide: false)
        }
        return perform(activation, for: row)
    }

    func perform(_ activation: StoneActivation, for row: StoneResultRow) -> StoneProviderActivationResult {
        guard case let .providerAction(action) = activation else { return .unhandled }

        if let id = id(from: action, prefix: "delete:") {
            return .confirmation(StoneProviderConfirmation(
                title: "Delete countdown?",
                message: "Return deletes this countdown. Escape cancels.",
                confirmationButtonTitle: "Confirm Deletion",
                confirmationActivation: .providerAction("delete-confirm:\(id.uuidString)")
            ))
        }

        if let id = id(from: action, prefix: "delete-confirm:") {
            guard store.remove(id: id) else {
                return .failed(message: store.lastError ?? "Could not delete this countdown.")
            }
            countdownsDidChange(store.countdowns)
            return .handled(shouldRefresh: true, resetSelection: true, shouldHide: false)
        }

        return .unhandled
    }

    static func rows(for countdowns: [Countdown], now: Date) -> [StoneResultRow] {
        let countdownRows = countdowns.map { countdown in
            StoneResultRow(
                id: .tool(kind: .message, key: "countdown:\(countdown.id.uuidString)"),
                display: countdown.name,
                subtitle: CountdownRemaining(until: countdown.nextTargetDate(after: now) ?? countdown.targetDate, now: now).displayString,
                copyText: nil,
                kind: .message,
                primaryActivation: .none,
                accessoryActivation: .providerAction("delete:\(countdown.id.uuidString)"),
                iconSystemImage: countdown.recurrence == .none ? "timer" : "repeat",
                accessoryText: countdown.recurrence == .none
                    ? "Target \(targetDateFormatter.string(from: countdown.targetDate))"
                    : "\(countdown.recurrence.title) · \(countdown.timeZoneIdentifier.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? countdown.timeZoneIdentifier)",
                accessoryPresentation: .init(systemImage: "trash", help: "Delete countdown"),
                countdownTarget: countdown.targetDate,
                countdownRecurrence: countdown.recurrence,
                countdownTimeZoneIdentifier: countdown.timeZoneIdentifier,
                options: CountdownRecurrence.allCases.map {
                    StoneResultOption(title: $0.title,
                                      activation: .providerAction("repeat:\(countdown.id.uuidString):\($0.rawValue)"),
                                      isSelected: $0 == countdown.recurrence)
                }
            )
        }

        return countdownRows
    }

    private static func help(for recurrence: CountdownRecurrence) -> String {
        switch recurrence {
        case .none: return "One-time countdown. Choose a future date and time."
        case .daily: return "Every day at this local time. Upcoming alerts are queued while Bucky is running."
        case .weekdays: return "Monday–Friday at this local time; weekend dates move to Monday."
        case .weekly: return "Every week on the selected weekday, at this local time."
        case .monthly: return "Same day each month; months without that day are skipped."
        case .yearly: return "Same date each year; February 29 repeats only in leap years."
        }
    }

    private func id(from action: String, prefix: String) -> UUID? {
        guard action.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(action.dropFirst(prefix.count)))
    }

    private static let targetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
