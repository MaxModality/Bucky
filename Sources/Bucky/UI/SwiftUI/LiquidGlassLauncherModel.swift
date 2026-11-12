import AppKit
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class LiquidGlassLauncherModel: ObservableObject {
    @Published var mode: LauncherMode = .applications
    @Published var query = ""
    @Published private(set) var filteredItemIDs: [AppRowID] = []
    @Published private var activatedFileBrowserModel: FileBrowserModel?
    @Published var selectedIndex = 0
    @Published var selectionScrollRequest: SelectionScrollRequest?
    @Published var isIndexing = false {
        didSet { refreshApplicationResultSnapshot() }
    }
    @Published var animationTiming: LauncherAnimationTiming
    @Published var isPresented = false {
        didSet {
            if !isPresented {
                cancelLiveStoneRefresh()
                cancelProviderConfirmation()
                warmCacheTask?.cancel()
                cancelPendingApplicationFilter()
            }
            updateActiveStoneLifecycle()
        }
    }
    @Published var isWindowKey = false
    @Published var isInlineCreationInputFocused = false
    @Published private(set) var inlineCreationSubmitRequestID = 0
    @Published var providerConfirmation: StoneProviderConfirmation?
    @Published var interactionError: String?
    @Published private(set) var isSubmittingInlineCreation = false
    @Published private(set) var isPerformingProviderAction = false
    @Published var isShowingSettings = false {
        didSet { updateActiveStoneLifecycle() }
    }
    @Published var isShowingHelp = false {
        didSet { updateActiveStoneLifecycle() }
    }
    @Published var isPinned = false {
        didSet { pinnedChangedAction?(isPinned) }
    }

    var hideAction: (() -> Void)?
    var openSettingsAction: (() -> Void)?
    var openHelpAction: (() -> Void)?
    var returnToLauncherAction: (() -> Void)?
    var reindexAction: (() -> Void)?
    var indexWatchPathsChanged: ((Set<String>) -> Void)?
    var pinnedChangedAction: ((Bool) -> Void)?
    var modeWillSwitchAction: ((LauncherMode, LauncherMode) -> Void)?
    var restoreFocusAction: (() -> Void)?

    private let settingsStore: SettingsStore
    private let inclusionStore: InclusionStore
    private let exclusionStore: ExclusionStore
    private let calculatorStone: CalculatorStone
    private let dictionaryHistoryStore: DictionaryHistoryStore
    private let stoneProviders: StoneProviderRegistry
    private let fileBrowserModelFactory: () -> FileBrowserModel
    private let applicationIndexSnapshotCache: ApplicationIndexSnapshotCache
    private let applicationIndexLoader: @Sendable (Set<String>) -> [LaunchItem]
    private var appRowStore = ApplicationRowStore()
    private let applicationSearchWorker = ApplicationSearchWorker()
    private var applicationSnapshotGeneration = 0
    private var hasReceivedLiveApplicationSnapshot = false
    @Published private var applicationResultSnapshot: StoneResultSnapshot = .empty(message: "No launchable items found")
    private var applicationResultSnapshotGeneration = -1
    private var applicationResultSnapshotIDs: [AppRowID] = []
    private var applicationResultRevision = 0
    private var applicationIconURLs: [URL] = []
    private var filterCache = ApplicationFilterCache()
    private var applicationQuery = ""
    private var textStoneQueries: [StoneID: String] = [:]
    @Published private var textStoneResultSnapshots: [StoneID: StoneResultSnapshot] = [:]
    private var needsReindexAfterCurrent = false
    private var pendingApplicationFilterTask: Task<Void, Never>?
    private var applicationFilterRequestGate = StoneResultRequestGate()
    private var pendingTextStoneUpdateTasks: [StoneID: Task<Void, Never>] = [:]
    private var textStoneRequestGates: [StoneID: StoneResultRequestGate] = [:]
    private var pendingModeSnapshotTask: Task<Void, Never>?
    private var modeSnapshotGeneration = 0
    private var liveStoneRefreshTask: Task<Void, Never>?
    private var warmCacheTask: Task<Void, Never>?
    private var selectionScrollRequestID = 0
    private var providerConfirmationRow: StoneResultRow?
    private var providerConfirmationStoneID: StoneID?

    init(
        settingsStore: SettingsStore,
        inclusionStore: InclusionStore,
        exclusionStore: ExclusionStore,
        calculationHistoryStore: CalculationHistoryStore,
        dictionaryHistoryStore: DictionaryHistoryStore = DictionaryHistoryStore(),
        dictionaryLookup: @escaping @Sendable (String) -> [DictionaryResult] = { DictionaryLookup.results(for: $0) },
        dictionaryOpenHandler: @escaping @MainActor (String) -> Void = LiquidGlassLauncherModel.openDictionaryTerm,
        textStoneProviders: [any StoneProvider] = [],
        stoneProviders: [any StoneProvider] = [],
        fileBrowserModel: FileBrowserModel? = nil,
        fileBrowserModelFactory: (() -> FileBrowserModel)? = nil,
        applicationIndexSnapshotCache: ApplicationIndexSnapshotCache = ApplicationIndexSnapshotCache(),
        applicationIndexLoader: @escaping @Sendable (Set<String>) -> [LaunchItem] = {
            ApplicationIndexer().load(includedPaths: $0)
        }
    ) {
        self.settingsStore = settingsStore
        self.inclusionStore = inclusionStore
        self.exclusionStore = exclusionStore
        let calculatorStone = CalculatorStone(store: calculationHistoryStore)
        self.calculatorStone = calculatorStone
        self.dictionaryHistoryStore = dictionaryHistoryStore
        let dictionaryStone = DictionaryStone(
            historyStore: dictionaryHistoryStore,
            lookup: dictionaryLookup,
            openHandler: dictionaryOpenHandler
        )
        let suppliedProviders = textStoneProviders + stoneProviders
        let suppliedIDs = Set(suppliedProviders.filter { StoneProviderRegistry.canRegister($0.definition) }
            .map { $0.definition.id })
        let builtInProviders: [any StoneProvider] = [calculatorStone, dictionaryStone]
        self.stoneProviders = StoneProviderRegistry(
            providers: builtInProviders.filter { !suppliedIDs.contains($0.definition.id) }
                + suppliedProviders
        )
        self.applicationIndexSnapshotCache = applicationIndexSnapshotCache
        self.applicationIndexLoader = applicationIndexLoader
        self.activatedFileBrowserModel = fileBrowserModel
        self.fileBrowserModelFactory = fileBrowserModelFactory ?? {
            MainActor.assumeIsolated {
                FileBrowserModel(startDirectory: settingsStore.settings.fileBrowserStartDirectory)
            }
        }
        animationTiming = settingsStore.settings.animationTiming
        calculatorStone.historyChanged = { [weak self, weak calculatorStone] in
            guard let self, let calculatorStone, self.mode.stoneID == calculatorStone.definition.id else { return }
            self.interactionError = calculatorStone.historyError
            self.applyToolsResults(scheduleHistory: false)
        }
        loadCachedApplicationSnapshot()
    }

    deinit {
        pendingApplicationFilterTask?.cancel()
        for task in pendingTextStoneUpdateTasks.values {
            task.cancel()
        }
        pendingModeSnapshotTask?.cancel()
        liveStoneRefreshTask?.cancel()
        warmCacheTask?.cancel()
    }

    var fileBrowserModel: FileBrowserModel {
        activateFileBrowserModel()
    }

    var filteredItems: [LaunchItem] {
        appRowStore.items(for: filteredItemIDs)
    }

    var filteredIconURLs: [URL] {
        applicationIconURLs
    }

    func item(for id: AppRowID) -> LaunchItem? {
        appRowStore.item(for: id)
    }

    var activeFileBrowserModel: FileBrowserModel? {
        activatedFileBrowserModel
    }

    var availableModes: [LauncherMode] {
        stoneProviders.availableModes
    }

    var inlineCreationConfiguration: StoneInlineCreationConfiguration? {
        (stoneProviders.provider(for: mode.stoneID) as? any InlineCreationStoneProvider)?.inlineCreationConfiguration
    }

    func mode(forCommandNumber commandNumber: Int) -> LauncherMode? {
        stoneProviders.mode(forShortcutNumber: commandNumber)
    }

    var placeholder: String {
        mode.placeholder
    }

    var resultCount: Int {
        if mode.stoneDefinition.surface.usesFileBrowser {
            return MainActor.assumeIsolated {
                fileBrowserModel.entries.count
            }
        }

        return resultSnapshot.rows.count
    }

    var canClearHistory: Bool {
        (stoneProviders.provider(for: mode.stoneID) as? any HistoryStoneProvider)?.canClearHistory == true
    }

    // Compatibility projection for existing callers; providers own the actual result state.
    var toolItems: [ToolItem] {
        resultSnapshot.rows.compactMap { row in
            let kind: ToolItem.Kind
            switch row.kind {
            case .calculation: kind = .calculation
            case .calculationHistory: kind = .calculationHistory
            case .message: kind = .message
            default: return nil
            }
            return ToolItem(title: row.display, subtitle: row.subtitle, copyText: row.copyText, kind: kind, stoneResultID: row.id)
        }
    }

    var emptyMessage: String? {
        guard !mode.stoneDefinition.surface.usesFileBrowser else {
            if MainActor.assumeIsolated({ fileBrowserModel.entries.isEmpty }) {
                return "No files"
            }
            return nil
        }

        return resultSnapshot.surfaceMessage
    }

    var resultSnapshot: StoneResultSnapshot {
        if let snapshot = textStoneResultSnapshots[mode.stoneID] {
            return snapshot
        }

        if mode == .applications {
            return applicationResultSnapshot
        }

        if mode.stoneDefinition.surface.usesFileBrowser {
            return .loaded(rows: MainActor.assumeIsolated { fileBrowserModel.entries.map(StoneResultRow.file) })
        }

        return .loaded(rows: [])
    }

    var resultSnapshotIdentity: String {
        mode == .applications ? "applications:\(applicationResultRevision)" : resultSnapshot.identity
    }

    private func refreshApplicationResultSnapshot() {
        if filteredItemIDs.isEmpty {
            let next: StoneResultSnapshot = isIndexing && appRowStore.isEmpty
                ? .loading(message: "Loading apps")
                : .empty(message: inputIsBlank ? "No launchable items found" : "No matches")
            guard applicationResultSnapshot != next else { return }
            applicationResultSnapshot = next
            applicationResultSnapshotIDs = []
            applicationResultSnapshotGeneration = -1
            applicationIconURLs = []
        } else {
            guard applicationResultSnapshotGeneration != appRowStore.generation
                    || applicationResultSnapshotIDs != filteredItemIDs else { return }
            let rows = filteredItemIDs.compactMap { id in
                appRowStore.item(for: id).map { StoneResultRow.application(id: id, item: $0) }
            }
            applicationResultSnapshot = .loaded(rows: rows)
            applicationResultSnapshotIDs = filteredItemIDs
            applicationResultSnapshotGeneration = appRowStore.generation
            applicationIconURLs = rows.compactMap(\.iconURL)
        }
        applicationResultRevision += 1
    }

    private func publishFilteredIDs(_ ids: [AppRowID]) {
        if filteredItemIDs != ids { filteredItemIDs = ids }
        refreshApplicationResultSnapshot()
        if isPresented { LauncherPerformanceTrace.shared.record(.resultsPublished) }
    }

    func resultRow(at index: Int) -> StoneResultRow? {
        let rows = resultSnapshot.rows
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    var inputIsBlank: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func show(mode: LauncherMode) {
        cancelLiveStoneRefresh()
        cancelPendingModeSnapshot()
        cancelPendingApplicationFilter()
        cancelPendingTextStoneUpdates()
        cancelProviderConfirmation()
        if isShowingSettings { isShowingSettings = false }
        if isShowingHelp { isShowingHelp = false }
        applicationQuery = ""
        textStoneQueries.removeAll()
        if self.mode != mode { self.mode = mode }
        let nextQuery = storedQuery(for: mode)
        if query != nextQuery { query = nextQuery }
        if selectedIndex != 0 { selectedIndex = 0 }
        if isPinned { isPinned = false }
        applyCurrentMode()
        updateActiveStoneLifecycle()
        requestSelectionScroll(anchor: .top)
    }

    func showSettings() {
        isShowingSettings = true
        isShowingHelp = false
        isPinned = false
    }

    func hideSettings() {
        isShowingSettings = false
    }

    func showHelp() {
        isShowingSettings = false
        isShowingHelp = true
        isPinned = false
    }

    func hideHelp() {
        isShowingHelp = false
    }

    func showLauncherSurface() {
        isShowingSettings = false
        isShowingHelp = false
    }

    func resetPanelVisibilityAfterHide() {
        isShowingSettings = false
        isShowingHelp = false
    }

    func setWindowKeyState(_ isWindowKey: Bool) {
        guard self.isWindowKey != isWindowKey else { return }
        self.isWindowKey = isWindowKey
    }

    func prepareFileBrowserMode() {
        guard mode.stoneDefinition.surface.usesFileBrowser else { return }
        let model = activateFileBrowserModel()
        selectedIndex = MainActor.assumeIsolated {
            model.selectedIndex
        }
    }

    func queryDidChange() {
        storeCurrentQuery()
        applyCurrentMode(preservePreviousOnEmpty: true)
    }

    func handle(command: LauncherCommand) -> Bool {
        if providerConfirmation != nil {
            switch command {
            case .open: confirmProviderConfirmation()
            case .close: cancelProviderConfirmation()
            default: break
            }
            return true
        }
        switch command {
        case .up:
            if mode.stoneDefinition.surface.usesFileBrowser {
                return handleFileBrowserCommand(command)
            }
            moveSelection(by: -1)
        case .down:
            if mode.stoneDefinition.surface.usesFileBrowser {
                return handleFileBrowserCommand(command)
            }
            moveSelection(by: 1)
        case .top:
            if mode.stoneDefinition.surface.usesFileBrowser {
                return handleFileBrowserCommand(command, anchor: .top)
            }
            moveSelection(to: 0, anchor: .top)
        case .bottom:
            if mode.stoneDefinition.surface.usesFileBrowser {
                return handleFileBrowserCommand(command, anchor: .bottom)
            }
            moveSelection(to: resultCount - 1, anchor: .bottom)
        case .open:
            if mode.stoneDefinition.surface.usesFileBrowser {
                return handleFileBrowserCommand(command)
            }
            activateSelected()
        case .close:
            if mode.stoneDefinition.surface.usesFileBrowser, fileBrowserFocusState != .browse {
                return handleFileBrowserCommand(command)
            }
            clearInputOrHide()
        case .reindex:
            reindex()
        case .settings:
            openSettingsAction?()
        case .help:
            openHelpAction?()
        case let .switchMode(nextMode):
            return switchMode(nextMode)
        case .previousMode:
            return switchMode(adjacentAvailableMode(offset: -1))
        case .nextMode:
            return switchMode(adjacentAvailableMode(offset: 1))
        case .clearHistory:
            clearHistory()
        case .togglePin:
            if mode.stoneDefinition.surface.usesFileBrowser {
                return handleFileBrowserCommand(command)
            }
            isPinned.toggle()
        case .left, .right, .prepareSpaceInteraction, .space, .shiftSpace, .beginSpaceHold, .endSpaceHold,
                .alphaNumeric, .shiftAlphaNumeric, .beginPinnedFocus, .endPinnedFocus, .historyBack, .historyForward:
            guard mode.stoneDefinition.surface.usesFileBrowser else { return false }
            return handleFileBrowserCommand(command)
        }

        return true
    }

    func reindex() {
        cancelPendingApplicationFilter()
        cancelPendingTextStoneUpdates()
        guard !isIndexing else {
            needsReindexAfterCurrent = true
            return
        }

        isIndexing = true
        needsReindexAfterCurrent = false
        Task { [weak self] in
            guard let self else { return }
            let inclusionsLoaded = await inclusionStore.loadAsync()
            let exclusionsLoaded = await exclusionStore.loadAsync()
            if !inclusionsLoaded || !exclusionsLoaded {
                interactionError = "Could not reload configuration. Preserved the last valid configuration and files."
            }
            let includedPaths = inclusionStore.includedPaths
            indexWatchPathsChanged?(includedPaths)
            let applicationIndexSnapshotCache = applicationIndexSnapshotCache
            let applicationIndexLoader = applicationIndexLoader
            DispatchQueue.global(qos: .userInitiated).async { [weak self, applicationIndexSnapshotCache] in
                let items = applicationIndexLoader(includedPaths)
                applicationIndexSnapshotCache.save(items)

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.hasReceivedLiveApplicationSnapshot = true
                    Task { [weak self] in
                        guard let self else { return }
                        await self.publishApplicationSnapshot(items)
                        self.isIndexing = false
                        if self.needsReindexAfterCurrent {
                            self.reindex()
                        } else if self.mode == .applications {
                            self.applyApplicationFilter()
                        }
                    }
                }
            }
        }
    }

    private func loadCachedApplicationSnapshot() {
        DispatchQueue.global(qos: .utility).async { [weak self, applicationIndexSnapshotCache] in
            let items = applicationIndexSnapshotCache.load()
            guard !items.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !self.hasReceivedLiveApplicationSnapshot else { return }
                Task { [weak self] in
                    guard let self else { return }
                    await self.publishApplicationSnapshot(items, isCached: true)
                    if self.mode == .applications { self.applyApplicationFilter() }
                }
            }
        }
    }

    // Prepares dictionaries, natural-title ranks, and visibility away from the UI executor.
    // A later index wins; exclusion edits during preparation are retried using latest values.
    private func publishApplicationSnapshot(_ items: [LaunchItem], isCached: Bool = false) async {
        guard !isCached || !hasReceivedLiveApplicationSnapshot else { return }
        applicationSnapshotGeneration += 1
        let requestGeneration = applicationSnapshotGeneration
        let previousRowStore = appRowStore
        var visibility = exclusionStore.visibilitySnapshot
        let initialVisibility = visibility
        let preparation = Task.detached(priority: .utility) {
            var store = previousRowStore
            store.replaceAll(items)
            store.rebuildVisibleIDs { !initialVisibility.isExcluded($0) }
            return store
        }
        var preparedStore = await withTaskCancellationHandler {
            await preparation.value
        } onCancel: { preparation.cancel() }
        while !Task.isCancelled {
            guard requestGeneration == applicationSnapshotGeneration,
                  !isCached || !hasReceivedLiveApplicationSnapshot else { return }
            let latestVisibility = exclusionStore.visibilitySnapshot
            if visibility != latestVisibility {
                visibility = latestVisibility
                let store = preparedStore
                preparedStore = await Task.detached(priority: .utility) {
                    var next = store
                    next.rebuildVisibleIDs { !latestVisibility.isExcluded($0) }
                    return next
                }.value
                continue
            }
            // An identical index must preserve cached search results and row storage.
            // Both checks matter: visibility can change on MainActor during preparation.
            if preparedStore.generation == previousRowStore.generation,
               appRowStore.generation == previousRowStore.generation { return }
            cancelPendingApplicationFilter()
            warmCacheTask?.cancel()
            preparedStore.advanceGeneration(after: appRowStore.generation)
            appRowStore = preparedStore
            filterCache.removeAll()
            // Blank input is the hotkey path and needs no search or ranking.
            if normalized(query).isEmpty { publishFilteredIDs(appRowStore.visibleIDs) }
            return
        }
    }

    func startBackgroundWarmCaches() {
        prewarmFilterCache(for: normalized(query))
    }

    func flushPersistence(completion: @escaping () -> Void) {
        // Flush only an already activated Files model; quitting must not initialize a Stone.
        let flushJSON: () -> Void = {
            Task { @MainActor in
                await JSONFilePersistence.flushAsync()
                completion()
            }
        }
        if let activatedFileBrowserModel {
            activatedFileBrowserModel.flushPersistence(completion: flushJSON)
        } else {
            flushJSON()
        }
    }

    func refreshAfterExclusionsChanged() {
        rebuildVisibleItems()
        guard mode == .applications else { return }
        applyApplicationFilter()
    }

    func refreshAfterSettingsChanged() {
        Task { [weak self] in
            guard let self else { return }
            guard await settingsStore.loadAsync() else {
                interactionError = settingsStore.lastError ?? "Could not reload settings."
                return
            }
            animationTiming = settingsStore.settings.animationTiming
            reindex()
        }
    }

    func exclude(_ item: LaunchItem) {
        cancelPendingApplicationFilter()
        Task { [weak self] in
            guard let self else { return }
            guard await exclusionStore.excludeAsync(item) else {
                interactionError = exclusionStore.lastError ?? "Could not hide this item."
                return
            }
            rebuildVisibleItems()
            if mode == .applications { applyApplicationFilter() }
        }
    }

    func exclude(_ row: StoneResultRow) {
        guard case let .application(id) = row.id,
              let item = appRowStore.item(for: id) else {
            return
        }

        exclude(item)
    }

    func clearHistory() {
        cancelPendingTextStoneUpdates()
        guard let provider = stoneProviders.provider(for: mode.stoneID) as? any HistoryStoneProvider else { return }
        let stoneID = mode.stoneID
        Task { [weak self, provider] in
            let saved = await provider.clearHistory()
            guard let self, self.mode.stoneID == stoneID else { return }
            if !saved { self.interactionError = provider.historyError ?? "Could not clear history." }
            self.applyToolsResults(scheduleHistory: false)
        }
    }

    func activate(_ row: StoneResultRow) {
        let activation = stoneProviders.activation(for: mode.stoneID, row: row) ?? row.primaryActivation
        perform(activation, for: row)
    }

    func performAccessoryActivation(for row: StoneResultRow) {
        perform(row.accessoryActivation, for: row)
    }

    @discardableResult
    func submitInlineCreation(name: String, targetDate: Date) -> Bool {
        guard let provider = stoneProviders.provider(for: mode.stoneID) as? any InlineCreationStoneProvider,
              provider.submitInlineCreation(name: name, targetDate: targetDate) else {
            return false
        }

        applyToolsResults(scheduleHistory: false)
        return true
    }

    func submitInlineCreationAsync(name: String, targetDate: Date, optionID: String? = nil) async -> Bool {
        guard providerConfirmation == nil, !isSubmittingInlineCreation, !isPerformingProviderAction,
              let provider = stoneProviders.provider(for: mode.stoneID) as? any InlineCreationStoneProvider else {
            return false
        }
        let stoneID = mode.stoneID
        isSubmittingInlineCreation = true
        interactionError = nil
        defer { isSubmittingInlineCreation = false }
        let saved = await provider.submitInlineCreationAsync(name: name, targetDate: targetDate, optionID: optionID)
        guard mode.stoneID == stoneID else { return false }
        guard saved else {
            interactionError = provider.inlineCreationError ?? "Choose a future target date and try again."
            return false
        }
        applyToolsResults(scheduleHistory: false)
        return true
    }

    func requestInlineCreationSubmit() {
        inlineCreationSubmitRequestID &+= 1
    }

    func confirmProviderConfirmation() {
        guard let confirmation = providerConfirmation,
              let row = providerConfirmationRow,
              let stoneID = providerConfirmationStoneID,
              let provider = stoneProviders.provider(for: stoneID) else {
            return
        }

        cancelProviderConfirmation()
        isPerformingProviderAction = true
        Task { [weak self, provider] in
            let result = await provider.performAsync(confirmation.confirmationActivation, for: row)
            guard let self else { return }
            self.isPerformingProviderAction = false
            guard self.mode.stoneID == stoneID else { return }
            self.handleProviderResult(result, activation: confirmation.confirmationActivation, row: row, stoneID: stoneID)
        }
    }

    func cancelProviderConfirmation() {
        providerConfirmation = nil
        providerConfirmationRow = nil
        providerConfirmationStoneID = nil
    }

    func cancelPendingCalculationHistory() {
        calculatorStone.cancel()
    }

    private func cancelPendingTextStoneUpdates() {
        for stoneID in stoneProviders.registeredStoneIDs {
            cancelPendingTextStoneUpdate(for: stoneID)
        }
    }

    private func cancelPendingTextStoneUpdate(for stoneID: StoneID) {
        var requestGate = textStoneRequestGates[stoneID] ?? StoneResultRequestGate()
        requestGate.cancel()
        textStoneRequestGates[stoneID] = requestGate
        stoneProviders.cancel(for: stoneID)
        pendingTextStoneUpdateTasks[stoneID]?.cancel()
        pendingTextStoneUpdateTasks[stoneID] = nil
    }

    private func beginTextStoneRequest(for stoneID: StoneID, query: String) -> StoneResultRequestGate.Token {
        var requestGate = textStoneRequestGates[stoneID] ?? StoneResultRequestGate()
        let token = requestGate.begin(query: query)
        textStoneRequestGates[stoneID] = requestGate
        return token
    }

    private func acceptsTextStoneRequest(
        _ token: StoneResultRequestGate.Token,
        for stoneID: StoneID,
        query: String
    ) -> Bool {
        textStoneRequestGates[stoneID]?.accepts(token, currentQuery: query) == true
    }

    private func cancelPendingApplicationFilter() {
        applicationFilterRequestGate.cancel()
        pendingApplicationFilterTask?.cancel()
        pendingApplicationFilterTask = nil
    }

    private func cancelPendingModeSnapshot() {
        modeSnapshotGeneration += 1
        pendingModeSnapshotTask?.cancel()
        pendingModeSnapshotTask = nil
    }

    private func scheduleLiveStoneRefresh(for provider: any StoneProvider) {
        cancelLiveStoneRefresh()

        guard isPresented, !isShowingSettings, !isShowingHelp,
              let interval = provider.definition.refreshIntervalNanoseconds else { return }
        let stoneID = provider.definition.id
        liveStoneRefreshTask = Task { [weak self, provider] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.isPresented, !self.isShowingSettings, !self.isShowingHelp,
                          self.mode.stoneID == stoneID else { return }
                    self.applyTextStoneSnapshot(provider.snapshot(for: self.query), for: stoneID)
                }
            }
        }
    }

    private func cancelLiveStoneRefresh() {
        liveStoneRefreshTask?.cancel()
        liveStoneRefreshTask = nil
    }

    private func updateActiveStoneLifecycle() {
        let visible = isPresented && !isShowingSettings && !isShowingHelp
        activatedFileBrowserModel?.setActive(visible && mode == .files)
        guard visible else {
            cancelLiveStoneRefresh()
            warmCacheTask?.cancel()
            cancelProviderConfirmation()
            return
        }
        if let provider = stoneProviders.provider(for: mode.stoneID) {
            scheduleLiveStoneRefresh(for: provider)
        }
    }

    private func activateFileBrowserModel() -> FileBrowserModel {
        if let activatedFileBrowserModel {
            return activatedFileBrowserModel
        }

        let model = fileBrowserModelFactory()
        activatedFileBrowserModel = model
        model.setActive(isPresented && !isShowingSettings && !isShowingHelp && mode == .files)
        return model
    }

    private func applyCurrentMode(preservePreviousOnEmpty: Bool = false) {
        if stoneProviders.provider(for: mode.stoneID) != nil {
            applyToolsResults()
            return
        }

        switch mode {
        case .applications:
            cancelPendingCalculationHistory()
            cancelPendingTextStoneUpdates()
            applyApplicationFilter(preservePreviousOnEmpty: preservePreviousOnEmpty)
        case .files:
            cancelPendingCalculationHistory()
            cancelPendingTextStoneUpdates()
            selectedIndex = MainActor.assumeIsolated {
                fileBrowserModel.selectedIndex
            }
        default:
            return
        }
    }

    private func applyFilter(preservePreviousOnEmpty: Bool = false) {
        let cacheKey = normalized(query)
        // Whitespace-only queries historically use scored ordering. Preserve that
        // behavior on the worker; only an actually empty query is unscored.
        guard cacheKey.isEmpty else {
            applyDeferredApplicationFilter(for: cacheKey, delayNanoseconds: 0,
                                           preservePreviousOnEmpty: preservePreviousOnEmpty)
            return
        }
        let nextIDs = filterCache.results(for: cacheKey, generation: appRowStore.generation) {
            appRowStore.visibleIDs
        }

        if preservePreviousOnEmpty,
           nextIDs.isEmpty,
           !filteredItemIDs.isEmpty,
           !inputIsBlank {
            return
        }

        publishFilteredIDs(nextIDs)
        prewarmFilterCache(for: cacheKey)
        clampSelection()
    }

    private func applyApplicationFilter(preservePreviousOnEmpty: Bool = false) {
        let cacheKey = normalized(query)
        warmCacheTask?.cancel()
        if let cached = filterCache.cachedResults(for: cacheKey, generation: appRowStore.generation) {
            cancelPendingApplicationFilter()
            if !preservePreviousOnEmpty || !cached.isEmpty || filteredItemIDs.isEmpty || inputIsBlank {
                publishFilteredIDs(cached)
                clampSelection()
            }
            prewarmFilterCache(for: cacheKey)
            return
        }
        switch ToolResultsSnapshotPolicy.update(for: .applications, query: query) {
        case .immediate:
            cancelPendingApplicationFilter()
            applyFilter(preservePreviousOnEmpty: preservePreviousOnEmpty)
        case let .deferred(delayNanoseconds):
            applyDeferredApplicationFilter(
                for: cacheKey,
                delayNanoseconds: delayNanoseconds,
                preservePreviousOnEmpty: preservePreviousOnEmpty
            )
        }
    }

    private func applyDeferredApplicationFilter(
        for cacheKey: String,
        delayNanoseconds: UInt64,
        preservePreviousOnEmpty: Bool
    ) {
        let token = applicationFilterRequestGate.begin(query: cacheKey)
        let rowStore = appRowStore
        let ids = appRowStore.visibleIDs
        let generation = appRowStore.generation
        let worker = applicationSearchWorker
        pendingApplicationFilterTask?.cancel()
        pendingApplicationFilterTask = Task(priority: .userInitiated) { [weak self] in
            // Zero-delay Apps searches start on the worker as soon as input changes.
            if delayNanoseconds > 0 {
                do { try await Task.sleep(nanoseconds: delayNanoseconds) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let nextItems: [AppRowID]
            do {
                nextItems = try await worker.filter(ids, rowStore: rowStore, query: cacheKey)
            } catch { return }
            guard !Task.isCancelled, let self,
                  self.mode == .applications,
                  self.appRowStore.generation == generation,
                  self.applicationFilterRequestGate.accepts(token, currentQuery: normalized(self.query)) else { return }
            self.pendingApplicationFilterTask = nil
            self.filterCache.store(nextItems, for: cacheKey, generation: generation)
            if preservePreviousOnEmpty, nextItems.isEmpty,
               !self.filteredItemIDs.isEmpty, !self.inputIsBlank { return }
            self.publishFilteredIDs(nextItems)
            self.prewarmFilterCache(for: cacheKey)
            self.clampSelection()
        }
    }

    private func rebuildVisibleItems() {
        cancelPendingApplicationFilter()
        warmCacheTask?.cancel()
        let visibility = exclusionStore.visibilitySnapshot
        appRowStore.rebuildVisibleIDs { !visibility.isExcluded($0) }
        filterCache.removeAll()
    }

    private func prewarmFilterCache(for normalizedQuery: String) {
        warmCacheTask?.cancel()
        guard isPresented, mode == .applications, !isShowingSettings, !isShowingHelp,
              !appRowStore.visibleIDs.isEmpty,
              !filterCache.missingDeletionQueries(for: normalizedQuery, generation: appRowStore.generation).isEmpty
                else { return }
        let worker = applicationSearchWorker
        warmCacheTask = Task(priority: .utility) { [weak self] in
            // Warming is useful only after typing has been idle; it must never lead input.
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.isPresented,
                  !self.isShowingSettings, !self.isShowingHelp,
                  self.mode == .applications, self.pendingApplicationFilterTask == nil,
                  normalized(self.query) == normalizedQuery else { return }
            let generation = self.appRowStore.generation
            let queries = self.filterCache.missingDeletionQueries(for: normalizedQuery, generation: generation)
            let rowStore = self.appRowStore
            let ids = rowStore.visibleIDs
            for query in queries {
                guard !Task.isCancelled else { return }
                let results: [AppRowID]
                do { results = try await worker.filter(ids, rowStore: rowStore, query: query) }
                catch { return }
                guard !Task.isCancelled, self.appRowStore.generation == generation,
                      self.pendingApplicationFilterTask == nil else { return }
                self.filterCache.store(results, for: query, generation: generation)
            }
        }
    }

    nonisolated static func filterIDs(
        _ ids: [AppRowID],
        rowStore: ApplicationRowStore,
        normalizedQuery: String
    ) -> [AppRowID] {
        ApplicationSearchEngine.filterIDs(ids, rowStore: rowStore, normalizedQuery: normalizedQuery)
    }

    nonisolated static func filter(_ items: [LaunchItem], normalizedQuery: String) -> [LaunchItem] {
        ApplicationSearchEngine.filter(items, normalizedQuery: normalizedQuery)
    }

    private func applyToolsResults(scheduleHistory: Bool = true) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelPendingCalculationHistory()

        if let provider = stoneProviders.provider(for: mode.stoneID) {
            scheduleLiveStoneRefresh(for: provider)
            let stoneID = provider.definition.id
            cancelPendingTextStoneUpdate(for: stoneID)

            switch ToolResultsSnapshotPolicy.update(for: mode, query: query) {
            case .immediate:
                let snapshot = (provider as? any HistoryStoneProvider)?.snapshot(for: trimmedQuery, recordingHistory: scheduleHistory)
                    ?? provider.snapshot(for: trimmedQuery)
                applyTextStoneSnapshot(snapshot, for: stoneID)
                if scheduleHistory, snapshot.rows.first?.kind == .calculation {
                    selectedIndex = 0
                    requestSelectionScroll(anchor: .top)
                }
            case let .deferred(delayNanoseconds):
                applyDeferredTextStoneResults(
                    for: provider,
                    query: trimmedQuery,
                    delayNanoseconds: delayNanoseconds
                )
            }
            return
        }

        cancelLiveStoneRefresh()

    }

    private func applyDeferredTextStoneResults(
        for provider: any StoneProvider,
        query: String,
        delayNanoseconds: UInt64
    ) {
        let stoneID = provider.definition.id
        let token = beginTextStoneRequest(for: stoneID, query: query)
        applyTextStoneSnapshot(provider.snapshot(for: query), for: stoneID)
        pendingTextStoneUpdateTasks[stoneID] = Task { [weak self, provider] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            let snapshot = await provider.updateSnapshot(for: query)

            guard !Task.isCancelled else { return }

            self?.applyTextStoneUpdate(snapshot, for: stoneID, query: query, token: token)
        }
    }


    private func applyTextStoneUpdate(
        _ snapshot: StoneResultSnapshot,
        for stoneID: StoneID,
        query: String,
        token: StoneResultRequestGate.Token
    ) {
        guard mode.stoneID == stoneID,
              acceptsTextStoneRequest(
                token,
                for: stoneID,
                query: self.query.trimmingCharacters(in: .whitespacesAndNewlines)
              ) else {
            return
        }

        pendingTextStoneUpdateTasks[stoneID] = nil
        applyTextStoneSnapshot(snapshot, for: stoneID)
    }

    private func applyTextStoneSnapshot(_ snapshot: StoneResultSnapshot, for stoneID: StoneID) {
        guard textStoneResultSnapshots[stoneID] != snapshot else { return }
        textStoneResultSnapshots[stoneID] = snapshot
        clampSelection()
    }


    private func clearInputOrHide() {
        if inputIsBlank {
            if isPinned {
                isPinned = false
            }
            hideAction?()
            return
        }

        query = ""
        storeCurrentQuery()
        cancelPendingTextStoneUpdates()
        applyCurrentMode()
    }

    private func storeCurrentQuery() {
        if stoneProviders.provider(for: mode.stoneID) != nil {
            textStoneQueries[mode.stoneID] = query
            return
        }

        switch mode {
        case .applications:
            applicationQuery = query
        case .files:
            break
        default:
            return
        }
    }

    private func storedQuery(for mode: LauncherMode) -> String {
        if stoneProviders.provider(for: mode.stoneID) != nil {
            return textStoneQueries[mode.stoneID] ?? ""
        }

        switch mode {
        case .applications:
            return applicationQuery
        case .files:
            return ""
        default:
            return ""
        }
    }

    private func switchMode(_ nextMode: LauncherMode) -> Bool {
        cancelProviderConfirmation()
        interactionError = nil
        isInlineCreationInputFocused = false
        if mode != nextMode {
            modeWillSwitchAction?(mode, nextMode)
        }
        cancelLiveStoneRefresh()
        cancelPendingTextStoneUpdates()
        cancelPendingApplicationFilter()
        storeCurrentQuery()
        mode = nextMode
        updateActiveStoneLifecycle()
        query = storedQuery(for: nextMode)
        selectedIndex = 0
        publishLightweightModeSnapshot(for: nextMode)
        scheduleModeSnapshot(for: nextMode)
        return true
    }

    private func adjacentAvailableMode(offset: Int) -> LauncherMode {
        guard let index = availableModes.firstIndex(of: mode) else { return mode }
        let nextIndex = (index + offset + availableModes.count) % availableModes.count
        return availableModes[nextIndex]
    }

    private func publishLightweightModeSnapshot(for mode: LauncherMode) {
        if stoneProviders.provider(for: mode.stoneID) != nil {
            textStoneResultSnapshots[mode.stoneID] = .loaded(rows: [])
        }
    }

    private func scheduleModeSnapshot(for mode: LauncherMode) {
        cancelPendingModeSnapshot()
        let generation = modeSnapshotGeneration
        pendingModeSnapshotTask = Task { [weak self] in
            await Task.yield()

            await MainActor.run { [weak self] in
                guard let self,
                      self.modeSnapshotGeneration == generation,
                      self.mode == mode else {
                    return
                }

                self.pendingModeSnapshotTask = nil
                self.applyCurrentMode()
                self.requestSelectionScroll(anchor: .top)
            }
        }
    }

    private var fileBrowserFocusState: FileBrowserFocusState {
        MainActor.assumeIsolated {
            fileBrowserModel.focusState
        }
    }

    private func handleFileBrowserCommand(
        _ command: LauncherCommand,
        anchor: SelectionScrollAnchor = .nearest
    ) -> Bool {
        let shouldHideAfterOpenAction = shouldHideAfterFocusedFileOpen(command)
        MainActor.assumeIsolated {
            fileBrowserModel.handle(command)
            selectedIndex = fileBrowserModel.selectedIndex
        }
        if shouldHideAfterOpenAction,
           MainActor.assumeIsolated({ fileBrowserModel.focusState == .browse && fileBrowserModel.statusMessage == nil }) {
            hideAction?()
        }
        requestSelectionScroll(anchor: anchor)
        return true
    }

    private func shouldHideAfterFocusedFileOpen(_ command: LauncherCommand) -> Bool {
        guard case .open = command else { return false }
        return MainActor.assumeIsolated {
            fileBrowserModel.focusState == .previewActions
                && fileBrowserModel.focusableActions.indices.contains(fileBrowserModel.focusedActionIndex)
                && fileBrowserModel.focusableActions[fileBrowserModel.focusedActionIndex] == .open
        }
    }

    private func moveSelection(by delta: Int) {
        guard resultCount > 0 else { return }
        let nextIndex = max(0, min(resultCount - 1, selectedIndex + delta))
        selectedIndex = nextIndex
        requestSelectionScroll(anchor: .nearest)
    }

    private func moveSelection(to index: Int, anchor: SelectionScrollAnchor) {
        guard resultCount > 0 else { return }
        selectedIndex = max(0, min(resultCount - 1, index))
        requestSelectionScroll(anchor: anchor)
    }

    private func clampSelection() {
        let nextIndex = resultCount > 0 ? max(0, min(resultCount - 1, selectedIndex)) : 0
        if selectedIndex != nextIndex { selectedIndex = nextIndex }
    }

    private func requestSelectionScroll(anchor: SelectionScrollAnchor) {
        guard resultCount > 0 else { return }
        selectionScrollRequestID += 1
        selectionScrollRequest = SelectionScrollRequest(
            id: selectionScrollRequestID,
            index: selectedIndex,
            anchor: anchor
        )
    }

    private func activateSelected() {
        if mode.stoneDefinition.surface.usesFileBrowser {
            MainActor.assumeIsolated {
                fileBrowserModel.handle(.open)
            }
            return
        }

        guard let row = resultRow(at: selectedIndex) else { return }
        activate(row)
    }

    private func launch(_ item: LaunchItem) {
        launch(item.launchTarget)
    }

    private func launch(_ target: LaunchTarget) {
        switch target {
        case let .application(url):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    NSLog("Bucky failed to open an application (error code %ld)", (error as NSError).code)
                }
            }
        case let .url(url):
            if !NSWorkspace.shared.open(url) {
                NSLog("Bucky failed to open a URL")
            }
        case let .shellCommand(command):
            runShellCommand(command)
        }
    }

    private func runShellCommand(_ command: String) {
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]

            do {
                try process.run()
            } catch {
                NSLog("Bucky failed to run a custom action (error code %ld)", (error as NSError).code)
            }
        }
    }

    func performOption(_ option: StoneResultOption, for row: StoneResultRow) {
        guard row.options.contains(option) else { return }
        perform(option.activation, for: row)
    }

    private func perform(_ activation: StoneActivation, for row: StoneResultRow) {
        guard providerConfirmation == nil, !isPerformingProviderAction, !isSubmittingInlineCreation else { return }
        if let provider = stoneProviders.provider(for: mode.stoneID), provider.performsActivationsAsynchronously {
            let stoneID = mode.stoneID
            isPerformingProviderAction = true
            Task { [weak self, provider] in
                let result = await provider.performAsync(activation, for: row)
                guard let self else { return }
                self.isPerformingProviderAction = false
                guard self.mode.stoneID == stoneID else { return }
                if !self.handleProviderResult(result, activation: activation, row: row, stoneID: stoneID) {
                    self.performSharedActivation(activation)
                }
            }
            return
        }
        let result = stoneProviders.perform(activation, for: mode.stoneID, row: row)
        if handleProviderResult(result, activation: activation, row: row, stoneID: mode.stoneID) { return }
        performSharedActivation(activation)
    }

    private func performSharedActivation(_ activation: StoneActivation) {
        switch activation {
        case let .copy(value):
            copyToPasteboard(value)
        case let .open(target):
            launch(target)
        case .removeHistory, .providerAction, .none:
            return
        }

        if !isPinned { hideAction?() }
    }

    @discardableResult
    private func handleProviderResult(_ result: StoneProviderActivationResult, activation: StoneActivation, row: StoneResultRow, stoneID: StoneID) -> Bool {
        switch result {
        case let .handled(shouldRefresh, resetSelection, shouldHide):
            if shouldRefresh, inputIsBlank {
                applyToolsResults(scheduleHistory: false)
            }
            if resetSelection {
                selectedIndex = 0
                requestSelectionScroll(anchor: .top)
            }
            if shouldHide, !isPinned {
                hideAction?()
            }
            if case .providerAction = activation {
                DispatchQueue.main.async { [weak self] in
                    self?.restoreFocusAction?()
                }
            }
            return true
        case let .confirmation(confirmation):
            providerConfirmation = confirmation
            providerConfirmationRow = row
            providerConfirmationStoneID = stoneID
            return true
        case let .failed(message):
            interactionError = message
            return true
        case .unhandled:
            return false
        }
    }

    private func copyToPasteboard(_ value: String?) {
        guard let value else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private static func openDictionaryTerm(_ term: String) {
        guard let escapedTerm = term.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "dict://\(escapedTerm)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

}

@available(macOS 26.0, *)
enum SelectionScrollAnchor: Equatable {
    case nearest
    case top
    case bottom
}

@available(macOS 26.0, *)
enum SelectionScrollAnimationPolicy {
    static func shouldAnimate(anchor: SelectionScrollAnchor) -> Bool {
        switch anchor {
        case .nearest:
            return false
        case .top, .bottom:
            return true
        }
    }
}

@available(macOS 26.0, *)
struct SelectionScrollRequest: Equatable {
    let id: Int
    let index: Int
    let anchor: SelectionScrollAnchor
}

@available(macOS 26.0, *)
struct ApplicationFilterCache {
    private var resultsByQuery: [String: [AppRowID]] = [:]
    private var queryOrder: [String] = []
    private var generation: Int?
    private let limit = 96

    mutating func results(for query: String, generation: Int, build: () -> [AppRowID]) -> [AppRowID] {
        resetIfNeeded(generation: generation)
        if let cachedResults = resultsByQuery[query] {
            markUsed(query)
            return cachedResults
        }

        let results = build()
        store(results, for: query)
        return results
    }

    mutating func cachedResults(for query: String, generation: Int) -> [AppRowID]? {
        resetIfNeeded(generation: generation)
        guard let results = resultsByQuery[query] else { return nil }
        markUsed(query)
        return results
    }

    mutating func missingDeletionQueries(for query: String, generation: Int) -> [String] {
        resetIfNeeded(generation: generation)
        var prefix = query
        var queries: [String] = []
        var depth = 0
        while !prefix.isEmpty && depth < 8 {
            prefix.removeLast()
            depth += 1
            if resultsByQuery[prefix] == nil { queries.append(prefix) }
        }
        if resultsByQuery[""] == nil && !queries.contains("") { queries.append("") }
        return queries
    }

    mutating func removeAll() {
        resultsByQuery.removeAll(keepingCapacity: true)
        queryOrder.removeAll(keepingCapacity: true)
    }

    mutating func store(_ results: [AppRowID], for query: String) {
        resultsByQuery[query] = results
        markUsed(query)
        trimIfNeeded()
    }

    mutating func store(_ results: [AppRowID], for query: String, generation: Int) {
        resetIfNeeded(generation: generation)
        store(results, for: query)
    }

    private mutating func markUsed(_ query: String) {
        queryOrder.removeAll { $0 == query }
        queryOrder.append(query)
    }

    private mutating func resetIfNeeded(generation: Int) {
        guard self.generation != generation else { return }
        self.generation = generation
        removeAll()
    }

    private mutating func trimIfNeeded() {
        while queryOrder.count > limit, let oldestQuery = queryOrder.first {
            queryOrder.removeFirst()
            resultsByQuery.removeValue(forKey: oldestQuery)
        }
    }
}
