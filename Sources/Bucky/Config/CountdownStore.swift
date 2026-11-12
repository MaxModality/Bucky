import Foundation

struct CountdownsFile: Codable {
    var countdowns: [Countdown]
}

final class CountdownStore {
    static let maximumCountdowns = 100
    private static let maximumFileBytes = 128 * 1_024
    private let fileManager = FileManager.default

    private(set) var countdowns: [Countdown] = []
    private(set) var lastError: String?
    private var canWrite = true
    private var isSaving = false
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? BuckyPaths.appSupportDirectory.appendingPathComponent("countdowns.json")
        load()
    }

    func load() {
        guard !isSaving else { return }
        do {
            let fileSize = try fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
            guard fileSize?.intValue ?? 0 <= Self.maximumFileBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
            let file = try JSONFilePersistence.read(
                CountdownsFile.self,
                from: fileURL,
                decoder: JSONFilePersistence.makeDecoder()
            )
            countdowns = Self.sanitized(file.countdowns)
            canWrite = countdowns.count == file.countdowns.count
            lastError = canWrite ? nil : "Some saved countdowns have invalid titles or duplicate IDs. The file is preserved; repair it before making changes."
        } catch CocoaError.fileReadNoSuchFile {
            countdowns = []
            canWrite = true
            lastError = nil
        } catch {
            canWrite = false
            lastError = "Could not read countdowns. The existing file has been preserved; repair it before making changes."
        }
    }

    @discardableResult
    func add(name: String, targetDate: Date, recurrence: CountdownRecurrence = .none,
             timeZoneIdentifier: String = TimeZone.current.identifier) -> Countdown? {
        guard let name = validatedNameForAddition(name) else { return nil }

        guard validSchedule(targetDate: targetDate, timeZoneIdentifier: timeZoneIdentifier) else { return nil }
        let countdown = Countdown(name: name, targetDate: targetDate, recurrence: recurrence,
                                  timeZoneIdentifier: timeZoneIdentifier)
        return save([countdown] + countdowns) ? countdown : nil
    }

    @discardableResult
    func update(id: UUID, name: String, targetDate: Date, recurrence: CountdownRecurrence? = nil,
                timeZoneIdentifier: String? = nil) -> Bool {
        guard let name = Self.normalizedName(name),
              let index = countdowns.firstIndex(where: { $0.id == id }) else {
            return false
        }

        var next = countdowns
        next[index].name = name
        let zone = timeZoneIdentifier ?? next[index].timeZoneIdentifier
        guard validSchedule(targetDate: targetDate, timeZoneIdentifier: zone) else { return false }
        next[index].targetDate = targetDate
        next[index].timeZoneIdentifier = zone
        if let recurrence { next[index].recurrence = recurrence }
        return save(next)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard let index = countdowns.firstIndex(where: { $0.id == id }) else {
            return false
        }

        var next = countdowns
        next.remove(at: index)
        return save(next)
    }

    private func save(_ next: [Countdown]) -> Bool {
        guard canWrite, !isSaving else { return false }
        do {
            try JSONFilePersistence.write(
                CountdownsFile(countdowns: next),
                to: fileURL,
                fileManager: fileManager,
                encoder: JSONFilePersistence.makeEncoder()
            )
            countdowns = next
            lastError = nil
            return true
        } catch {
            lastError = "Could not save countdowns. Check available disk space and permissions, then try again."
            return false
        }
    }

    @MainActor
    func addAsync(name: String, targetDate: Date, recurrence: CountdownRecurrence = .none,
                  timeZoneIdentifier: String = TimeZone.current.identifier) async -> Countdown? {
        guard let name = validatedNameForAddition(name) else { return nil }
        guard validSchedule(targetDate: targetDate, timeZoneIdentifier: timeZoneIdentifier) else { return nil }
        let countdown = Countdown(name: name, targetDate: targetDate, recurrence: recurrence,
                                  timeZoneIdentifier: timeZoneIdentifier)
        return await saveAsync([countdown] + countdowns) ? countdown : nil
    }

    @MainActor
    func updateAsync(id: UUID, recurrence: CountdownRecurrence, now: Date = Date()) async -> Bool {
        guard let index = countdowns.firstIndex(where: { $0.id == id }) else { return false }
        var next = countdowns
        if recurrence == .none, next[index].recurrence != .none {
            next[index].targetDate = next[index].nextTargetDate(after: now) ?? next[index].targetDate
        }
        next[index].recurrence = recurrence
        return await saveAsync(next)
    }

    @MainActor
    func removeAsync(id: UUID) async -> Bool {
        guard let index = countdowns.firstIndex(where: { $0.id == id }) else { return false }
        var next = countdowns
        next.remove(at: index)
        return await saveAsync(next)
    }

    @MainActor
    private func saveAsync(_ next: [Countdown]) async -> Bool {
        guard canWrite, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await JSONFilePersistence.writeAsync(CountdownsFile(countdowns: next), to: fileURL)
            countdowns = next
            lastError = nil
            return true
        } catch {
            lastError = "Could not save countdowns. Check available disk space and permissions, then try again."
            return false
        }
    }

    private func validatedNameForAddition(_ value: String) -> String? {
        guard canWrite, !isSaving else { return nil }
        guard countdowns.count < Self.maximumCountdowns else {
            lastError = "You already have \(Self.maximumCountdowns) countdowns. Delete one before adding another."
            return nil
        }
        guard let name = Self.normalizedName(value) else {
            lastError = "Enter a countdown title."
            return nil
        }
        return name
    }

    private func validSchedule(targetDate: Date, timeZoneIdentifier: String) -> Bool {
        guard targetDate.timeIntervalSinceReferenceDate.isFinite,
              TimeZone(identifier: timeZoneIdentifier) != nil else {
            lastError = "Choose a valid countdown date and time zone."
            return false
        }
        return true
    }

    private static func normalizedName(_ value: String) -> String? {
        let name = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return String(name.prefix(200))
    }

    private static func sanitized(_ values: [Countdown]) -> [Countdown] {
        var seenIDs = Set<UUID>()
        return values.compactMap { countdown in
            guard let name = normalizedName(countdown.name), seenIDs.insert(countdown.id).inserted else {
                return nil
            }
            var normalized = countdown
            normalized.name = name
            return normalized
        }
    }
}
