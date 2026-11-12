import Foundation

enum StoneResultSnapshot: Equatable {
    case loading(message: String)
    case empty(message: String)
    case message(StoneResultRow)
    case loaded(rows: [StoneResultRow])

    var rows: [StoneResultRow] {
        switch self {
        case .loading, .empty:
            return []
        case let .message(row):
            return [row]
        case let .loaded(rows):
            return rows
        }
    }

    var surfaceMessage: String? {
        switch self {
        case let .loading(message), let .empty(message):
            return message
        case .message, .loaded:
            return nil
        }
    }

    var identity: String {
        switch self {
        case let .loading(message):
            return "loading:\(message)"
        case let .empty(message):
            return "empty:\(message)"
        case let .message(row):
            return "message:\(row.identityKey)"
        case let .loaded(rows):
            return rows.map(\.identityKey).joined(separator: "\u{1F}")
        }
    }
}

struct StoneResultOption: Equatable, Hashable {
    let title: String
    let activation: StoneActivation
    let isSelected: Bool
}

struct StoneResultRow: Identifiable, Equatable, Hashable {
    struct AccessoryPresentation: Equatable, Hashable {
        let systemImage: String
        let help: String

        static let copy = Self(systemImage: "doc.on.doc", help: "Copy result")
        static let open = Self(systemImage: "arrow.up.right", help: "Open result")
        static let removeHistory = Self(systemImage: "trash", help: "Remove from history")

        static func `default`(for activation: StoneActivation) -> Self? {
            switch activation {
            case .copy:
                return .copy
            case .open:
                return .open
            case .removeHistory:
                return .removeHistory
            case .providerAction:
                return nil
            case .none:
                return nil
            }
        }
    }

    enum ID: Equatable, Hashable {
        case application(AppRowID)
        case tool(kind: Kind, key: String)
        case file(URL)

        var identityKey: String {
            switch self {
            case let .application(id):
                return "application:\(id.rawValue)"
            case let .tool(kind, key):
                return "tool:\(kind.rawValue):\(key)"
            case let .file(url):
                return "file:\(url.standardizedFileURL.path)"
            }
        }
    }

    enum Kind: String, Equatable, Hashable {
        case application
        case calculation
        case calculationHistory
        case dictionary
        case dictionaryHistory
        case message
        case file
    }

    let id: ID
    let display: String
    let subtitle: String
    let copyText: String?
    let kind: Kind
    let primaryActivation: StoneActivation
    let accessoryActivation: StoneActivation
    let accessoryPresentation: AccessoryPresentation?
    let iconURL: URL?
    let iconSystemImage: String?
    let accessoryText: String?
    let countdownTarget: Date?
    let countdownRecurrence: CountdownRecurrence
    let countdownTimeZoneIdentifier: String?
    let options: [StoneResultOption]

    init(
        id: ID,
        display: String,
        subtitle: String,
        copyText: String?,
        kind: Kind,
        primaryActivation: StoneActivation,
        accessoryActivation: StoneActivation,
        iconURL: URL? = nil,
        iconSystemImage: String? = nil,
        accessoryText: String? = nil,
        accessoryPresentation: AccessoryPresentation? = nil,
        countdownTarget: Date? = nil,
        countdownRecurrence: CountdownRecurrence = .none,
        countdownTimeZoneIdentifier: String? = nil,
        options: [StoneResultOption] = []
    ) {
        self.id = id
        self.display = display
        self.subtitle = subtitle
        self.copyText = copyText
        self.kind = kind
        self.primaryActivation = primaryActivation
        self.accessoryActivation = accessoryActivation
        self.accessoryPresentation = accessoryPresentation ?? AccessoryPresentation.default(for: accessoryActivation)
        self.iconURL = iconURL
        self.iconSystemImage = iconSystemImage
        self.accessoryText = accessoryText
        self.countdownTarget = countdownTarget
        self.countdownRecurrence = countdownRecurrence
        self.countdownTimeZoneIdentifier = countdownTimeZoneIdentifier
        self.options = options
    }

    var identityKey: String {
        [
            id.identityKey,
            display,
            subtitle,
            copyText ?? "",
            kind.rawValue,
            iconSystemImage ?? "",
            accessoryText ?? "",
            accessoryPresentation?.systemImage ?? "",
            accessoryPresentation?.help ?? "",
            countdownTarget.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
            countdownRecurrence.rawValue,
            countdownTimeZoneIdentifier ?? "",
            options.map { "\($0.title):\($0.isSelected):\($0.activation)" }.joined(separator: ",")
        ].joined(separator: "\u{1E}")
    }

    static func application(id: AppRowID, item: LaunchItem) -> StoneResultRow {
        StoneResultRow(
            id: .application(id),
            display: item.title,
            subtitle: item.subtitle,
            copyText: nil,
            kind: .application,
            primaryActivation: .open(item.launchTarget),
            accessoryActivation: .none,
            iconURL: item.url,
            accessoryText: item.category.title
        )
    }

    static func tool(_ item: ToolItem) -> StoneResultRow {
        let kind = StoneResultRow.Kind(toolKind: item.kind)
        let primaryActivation = Self.primaryActivation(for: item)
        let accessoryActivation = Self.accessoryActivation(for: item, primaryActivation: primaryActivation)

        return StoneResultRow(
            id: item.stoneResultID,
            display: item.title,
            subtitle: item.subtitle,
            copyText: item.copyText,
            kind: kind,
            primaryActivation: primaryActivation,
            accessoryActivation: accessoryActivation
        )
    }

    static func file(_ entry: FileBrowserEntry) -> StoneResultRow {
        StoneResultRow(
            id: .file(entry.url),
            display: entry.name,
            subtitle: entry.url.path,
            copyText: entry.url.path,
            kind: .file,
            primaryActivation: .none,
            accessoryActivation: .none,
            iconURL: entry.url
        )
    }

    private static func primaryActivation(for item: ToolItem) -> StoneActivation {
        switch item.kind {
        case .calculation, .calculationHistory:
            guard let copyText = item.copyText else { return .none }
            return .copy(copyText)
        case .message:
            return .none
        }
    }

    private static func accessoryActivation(
        for item: ToolItem,
        primaryActivation: StoneActivation
    ) -> StoneActivation {
        switch item.kind {
        case .calculation, .calculationHistory:
            return primaryActivation
        case .message:
            return .none
        }
    }
}

enum StoneActivation: Equatable, Hashable {
    case copy(String)
    case open(LaunchTarget)
    case removeHistory(StoneResultRow.ID)
    case providerAction(String)
    case none
}

struct StoneResultRequestGate: Equatable {
    struct Token: Equatable {
        let generation: Int
        let query: String
    }

    private(set) var generation = 0

    mutating func begin(query: String) -> Token {
        generation += 1
        return Token(generation: generation, query: query)
    }

    mutating func cancel() {
        generation += 1
    }

    func accepts(_ token: Token, currentQuery: String) -> Bool {
        generation == token.generation && currentQuery == token.query
    }
}

private extension StoneResultRow.Kind {
    init(toolKind: ToolItem.Kind) {
        switch toolKind {
        case .calculation:
            self = .calculation
        case .calculationHistory:
            self = .calculationHistory
        case .message:
            self = .message
        }
    }
}
