import Foundation

struct StoneID: RawRepresentable, CaseIterable, Identifiable, Hashable {
    let rawValue: Int

    static let applications = StoneID(rawValue: 1)
    static let calculator = StoneID(rawValue: 2)
    static let dictionary = StoneID(rawValue: 3)
    static let files = StoneID(rawValue: 4)
    static let countdowns = StoneID(rawValue: 5)
    // CaseIterable describes the built-in catalog, not dynamically registered providers.
    static var allCases: [StoneID] { StoneCatalog.orderedDefinitions.map(\.id) }

    var id: Self { self }
}

enum StoneSurface: Hashable {
    case textInput
    case sharedResults
    case fileBrowser

    enum ActiveModePresentation: Hashable {
        case textInput
        case sharedResults
        case fileBrowser
    }

    var acceptsTextInput: Bool {
        self == .textInput
    }

    var usesFileBrowser: Bool {
        self == .fileBrowser
    }

    var activeModePresentation: ActiveModePresentation {
        switch self {
        case .textInput:
            return .textInput
        case .sharedResults:
            return .sharedResults
        case .fileBrowser:
            return .fileBrowser
        }
    }
}

enum StoneUpdatePolicy: Equatable, Hashable {
    case immediate
    case deferred(delayNanoseconds: UInt64)
}

struct StoneTint: Equatable, Hashable {
    let activeHex: Int
    let panelHex: Int
    let iconHex: Int
    let darkModeIconHex: Int
}

struct StonePresentation: Equatable, Hashable {
    let title: String
    let placeholder: String
    let systemImage: String
}

struct StoneDefinition: Identifiable, Equatable, Hashable {
    let id: StoneID
    let shortcutNumber: Int
    let presentation: StonePresentation
    let surface: StoneSurface
    let updatePolicy: StoneUpdatePolicy
    let tint: StoneTint
    let refreshIntervalNanoseconds: UInt64?
    let animatesResultUpdates: Bool

    init(
        id: StoneID,
        shortcutNumber: Int,
        presentation: StonePresentation,
        surface: StoneSurface,
        updatePolicy: StoneUpdatePolicy,
        tint: StoneTint,
        refreshIntervalNanoseconds: UInt64? = nil,
        animatesResultUpdates: Bool = true
    ) {
        self.id = id
        self.shortcutNumber = shortcutNumber
        self.presentation = presentation
        self.surface = surface
        self.updatePolicy = updatePolicy
        self.tint = tint
        self.refreshIntervalNanoseconds = refreshIntervalNanoseconds
        self.animatesResultUpdates = animatesResultUpdates
    }

    var acceptsTextInput: Bool {
        surface.acceptsTextInput
    }
}

@MainActor
protocol StoneProvider: AnyObject {
    var definition: StoneDefinition { get }
    var performsActivationsAsynchronously: Bool { get }

    func snapshot(for query: String) -> StoneResultSnapshot
    func updateSnapshot(for query: String) async -> StoneResultSnapshot
    func cancel()
    func activation(for row: StoneResultRow) -> StoneActivation
    func perform(_ activation: StoneActivation, for row: StoneResultRow) -> StoneProviderActivationResult
    func performAsync(_ activation: StoneActivation, for row: StoneResultRow) async -> StoneProviderActivationResult
}

extension StoneProvider {
    var performsActivationsAsynchronously: Bool { false }
    func performAsync(_ activation: StoneActivation, for row: StoneResultRow) async -> StoneProviderActivationResult {
        perform(activation, for: row)
    }
}

typealias TextStoneProvider = StoneProvider

@MainActor
protocol HistoryStoneProvider: StoneProvider {
    var canClearHistory: Bool { get }
    var historyError: String? { get }
    func clearHistory() async -> Bool
    func snapshot(for query: String, recordingHistory: Bool) -> StoneResultSnapshot
}

struct StoneInlineCreationOption: Equatable, Hashable, Identifiable {
    let id: String
    let title: String
    let help: String
}

struct StoneInlineCreationConfiguration: Equatable, Hashable {
    // Deliberately a named-datetime creation contract, not a general form framework.
    let namePlaceholder: String
    let targetDateLabel: String
    let submitHelp: String
    let systemImage: String
    let defaultTargetDate: Date
    var options: [StoneInlineCreationOption] = []
    var optionLabel: String = "Repeat"
}

struct StoneProviderConfirmation: Equatable, Hashable {
    let title: String
    let message: String
    let confirmationButtonTitle: String
    let confirmationActivation: StoneActivation

    init(
        title: String,
        message: String,
        confirmationButtonTitle: String = "Confirm",
        confirmationActivation: StoneActivation
    ) {
        self.title = title
        self.message = message
        self.confirmationButtonTitle = confirmationButtonTitle
        self.confirmationActivation = confirmationActivation
    }
}

@MainActor
protocol InlineCreationStoneProvider: StoneProvider {
    var inlineCreationConfiguration: StoneInlineCreationConfiguration { get }
    var inlineCreationError: String? { get }

    func submitInlineCreation(name: String, targetDate: Date) -> Bool
    func submitInlineCreationAsync(name: String, targetDate: Date) async -> Bool
    func submitInlineCreationAsync(name: String, targetDate: Date, optionID: String?) async -> Bool
}

extension InlineCreationStoneProvider {
    func submitInlineCreationAsync(name: String, targetDate: Date, optionID: String?) async -> Bool {
        await submitInlineCreationAsync(name: name, targetDate: targetDate)
    }

    var inlineCreationError: String? { nil }

    func submitInlineCreationAsync(name: String, targetDate: Date) async -> Bool {
        submitInlineCreation(name: name, targetDate: targetDate)
    }
}

enum StoneProviderActivationResult: Equatable {
    case unhandled
    case handled(shouldRefresh: Bool, resetSelection: Bool, shouldHide: Bool)
    case confirmation(StoneProviderConfirmation)
    case failed(message: String)
}

typealias TextStoneActivationResult = StoneProviderActivationResult

@MainActor
final class StoneProviderRegistry {
    private let providersByID: [StoneID: any StoneProvider]
    let orderedDefinitions: [StoneDefinition]

    init(providers: [any StoneProvider]) {
        var providersByID: [StoneID: any StoneProvider] = [:]
        var orderedDefinitions = StoneCatalog.orderedDefinitions

        for provider in providers where Self.canRegister(provider.definition) {
            let previous = providersByID.updateValue(provider, forKey: provider.definition.id)
            precondition(previous == nil, "StoneProviderRegistry contains duplicate provider for \(provider.definition.id)")

            if let index = orderedDefinitions.firstIndex(where: { $0.id == provider.definition.id }) {
                orderedDefinitions[index] = provider.definition
            } else {
                orderedDefinitions.append(provider.definition)
            }
        }

        precondition(
            Set(orderedDefinitions.map(\.id)).count == orderedDefinitions.count,
            "StoneProviderRegistry contains duplicate Stone definitions"
        )
        precondition(
            Set(orderedDefinitions.map(\.shortcutNumber)).count == orderedDefinitions.count,
            "StoneProviderRegistry contains duplicate Stone shortcut numbers"
        )
        self.providersByID = providersByID
        self.orderedDefinitions = orderedDefinitions
    }

    static func canRegister(_ definition: StoneDefinition) -> Bool {
        definition.id != .files && !definition.surface.usesFileBrowser
    }

    var registeredStoneIDs: [StoneID] {
        orderedDefinitions.map(\.id).filter { providersByID[$0] != nil }
    }

    var availableModes: [LauncherMode] {
        orderedDefinitions.map(LauncherMode.init(definition:))
    }

    func mode(forShortcutNumber shortcutNumber: Int) -> LauncherMode? {
        guard let definition = orderedDefinitions.first(where: { $0.shortcutNumber == shortcutNumber }) else {
            return nil
        }
        return LauncherMode(definition: definition)
    }

    func provider(for id: StoneID) -> (any StoneProvider)? {
        providersByID[id]
    }

    func snapshot(for id: StoneID, query: String) -> StoneResultSnapshot? {
        providersByID[id]?.snapshot(for: query)
    }

    func updateSnapshot(for id: StoneID, query: String) async -> StoneResultSnapshot? {
        guard let provider = providersByID[id] else { return nil }
        return await provider.updateSnapshot(for: query)
    }

    func cancel(for id: StoneID) {
        providersByID[id]?.cancel()
    }

    func activation(for id: StoneID, row: StoneResultRow) -> StoneActivation? {
        providersByID[id]?.activation(for: row)
    }

    func perform(_ activation: StoneActivation, for id: StoneID, row: StoneResultRow) -> StoneProviderActivationResult {
        providersByID[id]?.perform(activation, for: row) ?? .unhandled
    }
}

enum StoneCatalog {
    static let orderedDefinitions: [StoneDefinition] = [
        StoneDefinition(
            id: .applications,
            shortcutNumber: 1,
            presentation: StonePresentation(
                title: "Apps",
                placeholder: "Search Apps Here",
                systemImage: "square.grid.2x2"
            ),
            surface: .textInput,
            updatePolicy: .deferred(delayNanoseconds: 0),
            tint: StoneTint(
                activeHex: 0x266EF6,
                panelHex: 0x08578A,
                iconHex: 0x0B3D91,
                darkModeIconHex: 0x9CC7FF
            )
        ),
        StoneDefinition(
            id: .calculator,
            shortcutNumber: 2,
            presentation: StonePresentation(
                title: "Calculator",
                placeholder: "Perform Calculations Here",
                systemImage: "123.rectangle.fill"
            ),
            surface: .textInput,
            updatePolicy: .immediate,
            tint: StoneTint(
                activeHex: 0xFFD300,
                panelHex: 0xFFC239,
                iconHex: 0x3A2B00,
                darkModeIconHex: 0xFFF0A3
            )
        ),
        StoneDefinition(
            id: .dictionary,
            shortcutNumber: 3,
            presentation: StonePresentation(
                title: "Dictionary",
                placeholder: "Search Dictionary Here",
                systemImage: "text.book.closed"
            ),
            surface: .textInput,
            updatePolicy: .deferred(delayNanoseconds: 80_000_000),
            tint: StoneTint(
                activeHex: 0xE429F2,
                panelHex: 0xBF00FF,
                iconHex: 0x6E1977,
                darkModeIconHex: 0xF5B8FF
            )
        ),
        StoneDefinition(
            id: .files,
            shortcutNumber: 4,
            presentation: StonePresentation(
                title: "Files",
                placeholder: "Browse Files",
                systemImage: "folder"
            ),
            surface: .fileBrowser,
            updatePolicy: .immediate,
            tint: StoneTint(
                activeHex: 0xFF0130,
                panelHex: 0xC60404,
                iconHex: 0x7A0018,
                darkModeIconHex: 0xFFA6B8
            )
        )
    ]

    private static let definitionsByID: [StoneID: StoneDefinition] = {
        var definitionsByID: [StoneID: StoneDefinition] = [:]

        for definition in orderedDefinitions {
            let previous = definitionsByID.updateValue(definition, forKey: definition.id)
            precondition(previous == nil, "StoneCatalog contains duplicate definition for \(definition.id)")
        }

        precondition(definitionsByID.count == orderedDefinitions.count, "StoneCatalog lost definitions while indexing by id")
        return definitionsByID
    }()

    private static let definitionsByShortcutNumber: [Int: StoneDefinition] = {
        var definitionsByShortcutNumber: [Int: StoneDefinition] = [:]

        for definition in orderedDefinitions {
            let previous = definitionsByShortcutNumber.updateValue(definition, forKey: definition.shortcutNumber)
            precondition(previous == nil, "StoneCatalog contains duplicate shortcut number \(definition.shortcutNumber)")
        }

        precondition(definitionsByShortcutNumber.count == orderedDefinitions.count, "StoneCatalog lost definitions while indexing by shortcut number")
        return definitionsByShortcutNumber
    }()

    static func definition(for id: StoneID) -> StoneDefinition {
        guard let definition = definitionsByID[id] else {
            preconditionFailure("StoneCatalog is missing definition for \(id)")
        }

        return definition
    }

    static func definition(forRawValue rawValue: Int) -> StoneDefinition? {
        definitionsByID[StoneID(rawValue: rawValue)]
    }

    static func definition(forShortcutNumber shortcutNumber: Int) -> StoneDefinition? {
        definitionsByShortcutNumber[shortcutNumber]
    }
}
