import Foundation

enum CountdownRecurrence: String, Codable, CaseIterable, Hashable, Sendable {
    case none, daily, weekdays, weekly, monthly, yearly

    var title: String {
        switch self {
        case .none: return "Never"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
}

struct Countdown: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var targetDate: Date
    var recurrence: CountdownRecurrence
    var timeZoneIdentifier: String

    init(id: UUID = UUID(), name: String, targetDate: Date,
         recurrence: CountdownRecurrence = .none,
         timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.id = id
        self.name = name
        self.targetDate = targetDate
        self.recurrence = recurrence
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, targetDate, recurrence, timeZoneIdentifier
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        targetDate = try values.decode(Date.self, forKey: .targetDate)
        recurrence = try values.decodeIfPresent(CountdownRecurrence.self, forKey: .recurrence) ?? .none
        timeZoneIdentifier = try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
            ?? TimeZone.current.identifier
        guard targetDate.timeIntervalSinceReferenceDate.isFinite,
              TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .timeZoneIdentifier, in: values,
                                                   debugDescription: "Invalid countdown date or time zone")
        }
    }

    /// Calculates from the original anchor without mutating or persisting missed occurrences.
    /// Invalid month days are skipped; missing local times move forward and repeated times use the first.
    func nextTargetDate(after now: Date) -> Date? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              targetDate.timeIntervalSinceReferenceDate.isFinite,
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        guard recurrence != .none else { return targetDate > now ? targetDate : nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let anchor = calendar.dateComponents([.month, .day, .weekday, .hour, .minute, .second], from: targetDate)
        if targetDate > now,
           recurrence != .weekdays || (2...6).contains(anchor.weekday ?? 0) { return targetDate }
        let fraction = targetDate.timeIntervalSinceReferenceDate
            - floor(targetDate.timeIntervalSinceReferenceDate)
        let start = calendar.startOfDay(for: max(now, targetDate)).addingTimeInterval(-1)

        func next(matching day: DateComponents) -> Date? {
            var cursor = start
            // At most today's occurrence and the next matching date, independent of the missed gap.
            for _ in 0..<2 {
                // Match calendar dates separately so a missing midnight does not skip a whole day.
                let date = day == DateComponents()
                    ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor))
                    : calendar.nextDate(after: cursor, matching: day, matchingPolicy: .strict,
                                        repeatedTimePolicy: .first)
                guard let date,
                      let localTime = calendar.date(bySettingHour: anchor.hour ?? 0,
                                                    minute: anchor.minute ?? 0,
                                                    second: anchor.second ?? 0,
                                                    of: date, matchingPolicy: .nextTime,
                                                    repeatedTimePolicy: .first) else { return nil }
                let candidate = localTime.addingTimeInterval(fraction)
                if candidate > now, candidate >= targetDate { return candidate }
                // Calendar day arithmetic also works across 23- and 25-hour days.
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else {
                    return nil
                }
                cursor = nextDay.addingTimeInterval(-1)
            }
            return nil
        }

        var day = DateComponents()
        switch recurrence {
        case .none: return nil
        case .daily: break
        case .weekdays:
            return (2...6).compactMap { weekday in
                var weekdayMatch = day
                weekdayMatch.weekday = weekday
                return next(matching: weekdayMatch)
            }.min()
        case .weekly: day.weekday = anchor.weekday
        case .monthly: day.day = anchor.day
        case .yearly:
            day.month = anchor.month
            day.day = anchor.day
        }
        return next(matching: day)
    }
}

struct CountdownRemaining: Equatable, Hashable {
    let days: Int
    let hours: Int
    let minutes: Int
    let seconds: Int
    let milliseconds: Int

    static let zero = Self(days: 0, hours: 0, minutes: 0, seconds: 0, milliseconds: 0)

    init(days: Int, hours: Int, minutes: Int, seconds: Int, milliseconds: Int) {
        self.days = days
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.milliseconds = milliseconds
    }

    init(until targetDate: Date, now: Date) {
        let rawInterval = targetDate.timeIntervalSince(now)
        let interval = rawInterval.isNaN ? 0 : max(0, rawInterval)
        let maximumMilliseconds = Double(Int.max / 2)
        let totalMilliseconds = Int(min(interval * 1_000, maximumMilliseconds).rounded(.down))
        let millisecondsPerSecond = 1_000
        let millisecondsPerMinute = millisecondsPerSecond * 60
        let millisecondsPerHour = millisecondsPerMinute * 60
        let millisecondsPerDay = millisecondsPerHour * 24

        var remainder = totalMilliseconds
        days = remainder / millisecondsPerDay
        remainder %= millisecondsPerDay
        hours = remainder / millisecondsPerHour
        remainder %= millisecondsPerHour
        minutes = remainder / millisecondsPerMinute
        remainder %= millisecondsPerMinute
        seconds = remainder / millisecondsPerSecond
        milliseconds = remainder % millisecondsPerSecond
    }

    var displayString: String {
        "\(days)d \(String(format: "%02d", hours))h \(String(format: "%02d", minutes))m "
            + "\(String(format: "%02d", seconds))s \(String(format: "%03d", milliseconds))ms"
    }
}
