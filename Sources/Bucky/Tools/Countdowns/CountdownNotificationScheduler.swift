import Foundation
import UserNotifications

/// A bounded queue preserves each recurrence's start date, which a native repeating
/// calendar trigger cannot express. Launch, edits, and an hourly refresh refill it.
enum CountdownNotificationPolicy {
    static let identifierPrefix = "bucky.countdown."
    static let maximumPendingRequests = 60

    struct Occurrence {
        let countdown: Countdown
        let date: Date

        var identifier: String {
            CountdownNotificationPolicy.identifierPrefix + countdown.id.uuidString
                + "." + String(format: "%.0f", date.timeIntervalSince1970.rounded(.up))
        }

        var dateComponents: DateComponents {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: countdown.timeZoneIdentifier) ?? .current
            // Calendar notifications have second precision. Round up so they never
            // arrive before a target that contains fractional seconds.
            let fireDate = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.up))
            var components = calendar.dateComponents(
                [.era, .year, .month, .day, .hour, .minute, .second], from: fireDate
            )
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            return components
        }
    }

    static func occurrences(
        for countdowns: [Countdown], after now: Date, limit: Int = maximumPendingRequests
    ) -> [Occurrence] {
        let boundedLimit = min(maximumPendingRequests, max(0, limit))
        var seen = Set<UUID>()
        var candidates = countdowns.compactMap { countdown -> Occurrence? in
            guard seen.insert(countdown.id).inserted,
                  let date = countdown.nextTargetDate(after: now) else { return nil }
            return Occurrence(countdown: countdown, date: date)
        }
        var result: [Occurrence] = []
        while result.count < boundedLimit, !candidates.isEmpty {
            candidates.sort {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.countdown.id.uuidString < $1.countdown.id.uuidString
            }
            let next = candidates.removeFirst()
            result.append(next)
            if let date = next.countdown.nextTargetDate(after: next.date), date > next.date {
                candidates.append(Occurrence(countdown: next.countdown, date: date))
            }
        }
        return result
    }

    /// Both legacy single-request IDs and occurrence IDs belong to their countdown.
    static func countdownID(for identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let remainder = identifier.dropFirst(identifierPrefix.count)
        return remainder.split(separator: ".", maxSplits: 1).first.flatMap { UUID(uuidString: String($0)) }
    }
}

@MainActor
final class CountdownNotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var updateGeneration = 0
    private var latestCountdowns: [Countdown] = []
    private var pendingUpdate: (countdowns: [Countdown], requestAuthorization: Bool, generation: Int)?
    private var synchronizationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    override init() {
        super.init()
        center.delegate = self
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
                catch { return }
                guard let self else { return }
                self.reconcile(self.latestCountdowns, requestAuthorization: false)
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        synchronizationTask?.cancel()
    }

    func restoreScheduledNotifications(for countdowns: [Countdown]) {
        reconcile(countdowns, requestAuthorization: false)
    }

    func countdownsDidChange(_ countdowns: [Countdown]) {
        reconcile(countdowns, requestAuthorization: true)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func reconcile(_ countdowns: [Countdown], requestAuthorization: Bool) {
        latestCountdowns = countdowns
        updateGeneration += 1
        let needsAuthorization = requestAuthorization || (pendingUpdate?.requestAuthorization ?? false)
        pendingUpdate = (countdowns, needsAuthorization, updateGeneration)
        guard synchronizationTask == nil else { return }

        // One worker serializes OS mutations. If an add finishes after an edit,
        // the next pass removes it before installing the latest snapshot.
        synchronizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let update = pendingUpdate, !Task.isCancelled {
                pendingUpdate = nil
                var settings = await center.notificationSettings()
                guard !Task.isCancelled else { break }
                if update.requestAuthorization, settings.authorizationStatus == .notDetermined {
                    do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
                    catch { continue }
                    guard !Task.isCancelled else { break }
                    settings = await center.notificationSettings()
                }
                guard isCurrent(update.generation),
                      settings.authorizationStatus == .authorized
                        || settings.authorizationStatus == .provisional else { continue }
                await synchronizePendingRequests(with: update.countdowns, generation: update.generation)
            }
            synchronizationTask = nil
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == updateGeneration
    }

    private func synchronizePendingRequests(with countdowns: [Countdown], generation: Int) async {
        let pendingRequests = await center.pendingNotificationRequests()
        guard isCurrent(generation) else { return }
        let delivered = await center.deliveredNotifications()
        guard isCurrent(generation) else { return }

        let unrelatedCount = pendingRequests.filter {
            !$0.identifier.hasPrefix(CountdownNotificationPolicy.identifierPrefix)
        }.count
        let occurrences = await Task.detached(priority: .utility) {
            CountdownNotificationPolicy.occurrences(
                for: countdowns, after: Date(),
                limit: CountdownNotificationPolicy.maximumPendingRequests - unrelatedCount
            )
        }.value
        guard isCurrent(generation) else { return }
        let desiredIdentifiers = Set(occurrences.map(\.identifier))
        let existingIDs = Set(countdowns.map(\.id))
        center.removePendingNotificationRequests(withIdentifiers: pendingRequests.map(\.identifier).filter {
            $0.hasPrefix(CountdownNotificationPolicy.identifierPrefix) && !desiredIdentifiers.contains($0)
        })
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter {
            guard let id = CountdownNotificationPolicy.countdownID(for: $0) else { return false }
            return !existingIDs.contains(id)
        })

        for occurrence in occurrences {
            guard isCurrent(generation) else { return }
            let content = UNMutableNotificationContent()
            content.title = "Countdown finished"
            content.body = occurrence.countdown.name
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: occurrence.identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: occurrence.dateComponents, repeats: false)
            )
            do {
                try await center.add(request)
            } catch {
                guard isCurrent(generation) else { return }
                // Permission denial is not transient; only other failures get one
                // delayed retry, and the serialized worker bounds retry lifetime.
                let error = error as NSError
                guard !(error.domain == UNErrorDomain
                        && error.code == UNError.Code.notificationsNotAllowed.rawValue) else { continue }
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { return }
                guard isCurrent(generation) else { return }
                try? await center.add(request)
            }
            guard isCurrent(generation) else { return }
        }
    }
}
