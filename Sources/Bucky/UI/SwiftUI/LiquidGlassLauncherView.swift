import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct LiquidGlassLauncherView: View {
    @ObservedObject var model: LiquidGlassLauncherModel
    @ObservedObject var settingsModel: SettingsViewModel
    @FocusState private var isSearchFocused: Bool
    @Namespace private var selectionGlassNamespace
    @State private var handledSelectionScrollRequestID = 0
    @State private var iconPreloadTask: Task<Void, Never>?
    @State private var scrollTargetID: StoneResultRow.ID?
    @State private var scrollTargetAnchor: UnitPoint?
    @State private var inlineCreationName = ""
    @State private var inlineCreationTargetDate = Date()
    @State private var inlineCreationOptionID = "none"
    @State private var inlineCreationNameIsInvalid = false
    @FocusState private var inlineCreationFocus: InlineCreationField?

    private enum InlineCreationField: Hashable {
        case name
        case date
        case time
    }

    private var resultUpdateAnimation: Animation {
        model.animationTiming.animation(duration: 0.08)
    }

    private var selectionScrollAnimation: Animation {
        model.animationTiming.animation(duration: 0.08)
    }

    private var toolSnapshotUpdateAnimation: Animation {
        model.animationTiming.animation(duration: 0.08)
    }

    private var settingsModeAnimation: Animation {
        model.animationTiming.animation(duration: 0.16)
    }

    private var settingsModeTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.985))
    }

    var body: some View {
        ZStack {
            // Apps stays mounted, including its SwiftUI field editor and lazy list.
            // Heavy Stones retain their normal disappearance/cancellation lifecycle.
            if model.mode == .applications || model.isPresented {
                activeSurface
                    .allowsHitTesting(model.isPresented)
                    .accessibilityHidden(!model.isPresented)
            }
        }
        .onAppear {
            synchronizeSearchFocus()
            preloadApplicationIcons()
            resetInlineCreationDraftIfNeeded()
        }
        .onChange(of: model.mode) {
            synchronizeSearchFocus(afterModeChange: true)
            preloadApplicationIcons()
            resetInlineCreationDraftIfNeeded()
        }
        .onChange(of: model.isShowingSettings) {
            synchronizeSearchFocus()
            preloadApplicationIcons()
        }
        .onChange(of: model.isShowingHelp) {
            synchronizeSearchFocus()
            preloadApplicationIcons()
        }
        .onChange(of: model.isPresented) { _, isPresented in
            if isPresented {
                synchronizeSearchFocus()
                preloadApplicationIcons()
                resetInlineCreationDraftIfNeeded()
            } else {
                if model.mode != .applications { isSearchFocused = false }
                inlineCreationFocus = nil
                model.isInlineCreationInputFocused = false
                iconPreloadTask?.cancel()
                iconPreloadTask = nil
            }
        }
        .onChange(of: model.isWindowKey) { _, isWindowKey in
            if isWindowKey {
                synchronizeSearchFocus()
            }
        }
        .onChange(of: inlineCreationFocus) { _, focus in
            model.isInlineCreationInputFocused = focus != nil
        }
        .onChange(of: model.providerConfirmation) { _, confirmation in
            if confirmation != nil {
                isSearchFocused = false
                inlineCreationFocus = nil
            } else {
                synchronizeSearchFocus()
                focusInlineCreationTitleWhenMounted()
            }
        }
        .onChange(of: inlineCreationName) { _, _ in
            inlineCreationNameIsInvalid = false
        }
        .onChange(of: model.inlineCreationSubmitRequestID) { _, _ in
            guard let configuration = model.inlineCreationConfiguration else { return }
            submitInlineCreation(configuration)
        }
        .onChange(of: model.query) {
            preloadApplicationIcons()
        }
        .onChange(of: model.filteredItemIDs) {
            preloadApplicationIcons()
        }
        .animation(resultUpdateAnimation, value: model.mode)
        .animation(settingsModeAnimation, value: model.isShowingSettings)
        .animation(settingsModeAnimation, value: model.isShowingHelp)
    }

    @ViewBuilder
    private var activeSurface: some View {
        ZStack {
            Group {
                if model.isShowingSettings {
                    settingsSurface
                        .transition(settingsModeTransition)
                } else if model.isShowingHelp {
                    helpSurface
                        .transition(settingsModeTransition)
                } else {
                    launcherSurface
                        .transition(settingsModeTransition)
                }
            }
            .disabled(model.providerConfirmation != nil)
            .allowsHitTesting(model.providerConfirmation == nil)
            .accessibilityHidden(model.providerConfirmation != nil)

            if let confirmation = model.providerConfirmation {
                ConfirmationOverlay(
                    title: confirmation.title,
                    message: confirmation.message,
                    confirmationButtonTitle: confirmation.confirmationButtonTitle,
                    confirm: { model.confirmProviderConfirmation() }
                )
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
    }

    private var launcherSurface: some View {
        resultsPane
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var settingsSurface: some View {
        SettingsView(model: settingsModel, onBack: {
            model.returnToLauncherAction?()
        })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    private var helpSurface: some View {
        HelpView(globalHotKeyTitle: settingsModel.hotKeyTitle, modes: model.availableModes, onBack: {
            model.returnToLauncherAction?()
        })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    private func synchronizeSearchFocus(afterModeChange: Bool = false) {
        // FocusState is idempotent: do not clear/requeue an already mounted input.
        // The first focus request waits for presentation; requesting it against
        // a never-shown host can be rejected by SwiftUI's focus system.
        let shouldFocus = model.isPresented
            && !model.isShowingSettings && !model.isShowingHelp
            && model.providerConfirmation == nil && model.mode.acceptsTextInput
        if afterModeChange, shouldFocus {
            let requestedMode = model.mode
            isSearchFocused = false
            DispatchQueue.main.async {
                guard model.isPresented,
                      !model.isShowingSettings,
                      !model.isShowingHelp,
                      model.providerConfirmation == nil,
                      model.mode == requestedMode,
                      model.mode.acceptsTextInput else {
                    return
                }
                isSearchFocused = true
            }
        } else if isSearchFocused != shouldFocus {
            isSearchFocused = shouldFocus
        }
        if model.isPresented && shouldFocus {
            LauncherPerformanceTrace.shared.record(.focusRequested)
        }
    }

    private var header: some View {
        ModeSwitcherView(model: model, isSearchFocused: $isSearchFocused)
            .padding(.top, ModeSwitcherLayoutPolicy.launcherHeaderTopInset)
            .padding(.horizontal, ModeSwitcherLayoutPolicy.launcherHeaderHorizontalInset)
            .padding(.bottom, ModeSwitcherLayoutPolicy.launcherHeaderBottomInset)
            .padding(.horizontal, LauncherVisualStyle.resultsPaneContentInset)
            .padding(.top, LauncherVisualStyle.resultsPaneContentInset)
    }

    private var resultsPane: some View {
        ZStack {
            resultsPaneBackdrop

            VStack(spacing: LauncherVisualStyle.paneContentSpacing) {
                header

                if let error = model.interactionError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .accessibilityLabel("Error: \(error)")
                }

                results
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(resultsPaneShape)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(resultsPaneShape)
    }

    private var resultsPaneBackdrop: some View {
        LauncherBackdrop(
            tint: LauncherModeTintPolicy.panelColor(for: model.mode)
        )
        .overlay {
            resultsPaneShape
                .strokeBorder(
                    LauncherPinnedBorderPolicy.color(isPinned: model.isPinned),
                    lineWidth: LauncherPinnedBorderPolicy.lineWidth(isPinned: model.isPinned)
                )
        }
    }

    private var resultsPaneShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LauncherVisualStyle.resultsPaneCornerRadius, style: .continuous)
    }

    @ViewBuilder
    private var results: some View {
        if model.mode.stoneDefinition.surface.usesFileBrowser {
            fileBrowserResults
        } else {
            stoneResults(model.resultSnapshot)
        }
    }

    @ViewBuilder
    private var fileBrowserResults: some View {
        if let fileBrowserModel = model.activeFileBrowserModel {
            FileBrowserView(
                model: fileBrowserModel,
                selectionTint: LauncherModeTintPolicy.selectionColor(for: model.mode)
            )
                .transition(.opacity)
        } else {
            SkeletonLoadingView(label: "Loading files", surface: .fileResults)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    await Task.yield()
                    model.prepareFileBrowserMode()
                }
        }
    }

    @ViewBuilder
    private func stoneResults(_ snapshot: StoneResultSnapshot) -> some View {
        switch snapshot {
        case let .loading(message):
            SkeletonLoadingView(label: message, surface: .launcherResults)
                .transition(.opacity)
        case let .empty(message):
            surfaceMessage(message)
        case .message, .loaded:
            resultContent(snapshot)
        }
    }

    private func surfaceMessage(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
    }

    private func resultContent(_ snapshot: StoneResultSnapshot) -> some View {
        resultScrollView(reconstructionID: model.resultSnapshotIdentity) {
            if let configuration = model.inlineCreationConfiguration {
                inlineCreationRow(configuration)
            }

            ForEach(snapshot.rows) { row in
                stoneRow(row)
                    .transition(rowTransition(for: row))
            }
        }
        .animation(
            model.mode.stoneDefinition.animatesResultUpdates ? toolSnapshotAnimation(for: snapshot) : nil,
            value: model.resultSnapshotIdentity
        )
    }

    private func inlineCreationRow(_ configuration: StoneInlineCreationConfiguration) -> some View {
        LauncherResultRow(
            isSelected: false,
            selectionTint: LauncherModeTintPolicy.selectionColor(for: model.mode),
            selectionNamespace: selectionGlassNamespace,
            verticalPadding: 10,
            minHeight: 82
        ) {
            HStack(spacing: 12) {
                Image(systemName: configuration.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LauncherModeTintPolicy.activeColor(for: model.mode))
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 7) {
                    TextField(configuration.namePlaceholder, text: $inlineCreationName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .focused($inlineCreationFocus, equals: .name)
                        .padding(.bottom, 2)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Color.red.opacity(inlineCreationNameIsInvalid ? 0.82 : 0))
                                .frame(height: 1.5)
                        }
                        .accessibilityLabel(configuration.namePlaceholder)
                        .accessibilityHint(inlineCreationNameIsInvalid ? "A title is required before creating a countdown." : "")
                        .onSubmit {
                            submitInlineCreation(configuration)
                        }

                    HStack(spacing: 7) {
                        Text("Date")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        DatePicker(
                            configuration.targetDateLabel,
                            selection: $inlineCreationTargetDate,
                            displayedComponents: [.date]
                        )
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .controlSize(.small)
                        .fixedSize()
                        .glassEffect(.regular.interactive(true), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .focused($inlineCreationFocus, equals: .date)
                        .accessibilityLabel("Target date")

                        Text("Time")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        DatePicker(
                            configuration.targetDateLabel,
                            selection: $inlineCreationTargetDate,
                            displayedComponents: [.hourAndMinute]
                        )
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .controlSize(.small)
                        .fixedSize()
                        .glassEffect(.regular.interactive(true), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .focused($inlineCreationFocus, equals: .time)
                        .accessibilityLabel("Target time")
                    }

                    if !configuration.options.isEmpty {
                        Picker(configuration.optionLabel, selection: $inlineCreationOptionID) {
                            ForEach(configuration.options) { option in
                                Text(option.title).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel(configuration.optionLabel)

                        Text(configuration.options.first { $0.id == inlineCreationOptionID }?.help ?? "")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Alerts: next 60 occurrences across your countdowns. Bucky refills the queue while running.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    submitInlineCreation(configuration)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .background {
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.34))
                }
                .foregroundStyle(LauncherModeTintPolicy.activeColor(for: model.mode))
                .help(configuration.submitHelp)
                .launcherActionButtonRim()
                .disabled(!isInlineCreationTargetDateValid || model.isSubmittingInlineCreation)
                .opacity(isInlineCreationTargetDateValid ? 1 : 0.45)
            }
            .padding(.vertical, 2)
            .disabled(model.isSubmittingInlineCreation)
        }
        .background {
            RoundedRectangle(cornerRadius: LauncherResultListLayoutPolicy.rowCornerRadius, style: .continuous)
                .fill(.thinMaterial.opacity(0.45))
        }
        .overlay {
            RoundedRectangle(cornerRadius: LauncherResultListLayoutPolicy.rowCornerRadius, style: .continuous)
                .stroke(LauncherModeTintPolicy.activeColor(for: model.mode).opacity(0.24), lineWidth: 1)
        }
        .onAppear {
            focusInlineCreationTitleWhenMounted()
        }
    }

    private var isInlineCreationTargetDateValid: Bool {
        inlineCreationTargetDate > Date()
    }

    private func submitInlineCreation(_ configuration: StoneInlineCreationConfiguration) {
        guard !inlineCreationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            inlineCreationNameIsInvalid = true
            inlineCreationFocus = .name
            return
        }

        let name = inlineCreationName
        let date = inlineCreationTargetDate
        let optionID = inlineCreationOptionID
        let stoneID = model.mode.stoneID
        Task { @MainActor in
            guard await model.submitInlineCreationAsync(name: name, targetDate: date, optionID: optionID),
                  model.mode.stoneID == stoneID else { return }
            inlineCreationName = ""
            inlineCreationNameIsInvalid = false
            inlineCreationTargetDate = configuration.defaultTargetDate
            inlineCreationOptionID = configuration.options.first?.id ?? "none"
            inlineCreationFocus = .name
        }
    }

    private func resetInlineCreationDraftIfNeeded() {
        guard model.inlineCreationConfiguration != nil else {
            inlineCreationFocus = nil
            model.isInlineCreationInputFocused = false
            return
        }

        inlineCreationName = ""
        inlineCreationNameIsInvalid = false
        inlineCreationTargetDate = model.inlineCreationConfiguration?.defaultTargetDate ?? Date()
        inlineCreationOptionID = model.inlineCreationConfiguration?.options.first?.id ?? "none"
        inlineCreationFocus = .name
    }

    private func focusInlineCreationTitleWhenMounted() {
        DispatchQueue.main.async {
            guard model.isPresented,
                  !model.isShowingSettings,
                  !model.isShowingHelp,
                  model.providerConfirmation == nil,
                  model.inlineCreationConfiguration != nil else {
                return
            }
            inlineCreationFocus = .name
        }
    }

    private func resultScrollView<Content: View>(
        reconstructionID: AnyHashable,
        usesEagerRows: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        LauncherResultList(
            scrollTargetID: $scrollTargetID,
            scrollTargetAnchor: scrollTargetAnchor,
            reconstructionID: reconstructionID,
            reconstructionAnimation: model.mode.stoneDefinition.animatesResultUpdates
                ? .smooth(duration: LauncherResultListLayoutPolicy.rowReconstructionAnimationSeconds)
                : nil,
            usesEagerRows: usesEagerRows,
            content: content
        )
        .onAppear {
            if let request = model.selectionScrollRequest,
               request.id != handledSelectionScrollRequestID {
                handleSelectionScrollRequest(request)
            }
        }
        .onChange(of: model.selectionScrollRequest) { _, request in
            guard let request else { return }
            handleSelectionScrollRequest(request)
        }
    }

    private func selectResult(_ row: StoneResultRow) {
        guard let index = model.resultSnapshot.rows.firstIndex(where: { $0.id == row.id }) else { return }
        model.selectedIndex = index
    }

    private func stoneRow(_ row: StoneResultRow) -> some View {
        let isSelected = model.resultRow(at: model.selectedIndex)?.id == row.id
        let actionConfiguration = row.accessoryPresentation

        return LauncherResultRow(
            isSelected: isSelected,
            selectionTint: LauncherModeTintPolicy.selectionColor(for: model.mode),
            selectionNamespace: selectionGlassNamespace,
            verticalPadding: row.kind == .application ? 10 : 11
        ) {
            HStack(spacing: 14) {
                HStack(spacing: 14) {
                    rowIcon(for: row)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.display)
                            .font(rowTitleFont(for: row.kind))
                            .lineLimit(1)
                        Group {
                            if let target = row.countdownTarget {
                                LiveRemainingTimeText(target: target, recurrence: row.countdownRecurrence, timeZoneIdentifier: row.countdownTimeZoneIdentifier)
                            } else {
                                Text(row.subtitle)
                            }
                        }
                            .font(rowSubtitleFont(for: row.kind))
                            .foregroundStyle(.secondary)
                            .lineLimit(row.kind == .application ? 1 : 2)
                    }

                    Spacer(minLength: 12)

                    if let accessoryText = row.accessoryText {
                        Text(accessoryText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .accessibilityLabel("Result type: \(accessoryText)")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.inlineCreationConfiguration != nil {
                        inlineCreationFocus = nil
                    }
                    selectResult(row)
                    model.activate(row)
                }

                if !row.options.isEmpty {
                    Menu {
                        ForEach(Array(row.options.enumerated()), id: \.offset) { _, option in
                            Button {
                                model.performOption(option, for: row)
                            } label: {
                                if option.isSelected {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "repeat")
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Change repeat schedule")
                    .accessibilityLabel("Repeat schedule for \(row.display)")
                    .disabled(model.isPerformingProviderAction || model.isSubmittingInlineCreation)
                }

                if row.kind == .application {
                    Button {
                        model.exclude(row)
                    } label: {
                        Image(systemName: "eye.slash")
                            .frame(width: 16, height: 16)
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .background {
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.34))
                    }
                    .foregroundStyle(.secondary)
                    .help("Hide from results")
                    .launcherActionButtonRim()
                } else if let actionConfiguration {
                    Button {
                        selectResult(row)
                        model.performAccessoryActivation(for: row)
                    } label: {
                        Image(systemName: actionConfiguration.systemImage)
                            .frame(width: 16, height: 16)
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .background {
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.34))
                    }
                    .foregroundStyle(.secondary)
                    .help(actionConfiguration.help)
                    .launcherActionButtonRim()
                }
            }
        }
        .id(row.id)
    }

    private func handleSelectionScrollRequest(_ request: SelectionScrollRequest) {
        guard request.id != handledSelectionScrollRequestID else { return }
        scrollSelectedRow(request)
        handledSelectionScrollRequestID = request.id
    }

    private func scrollSelectedRow(_ request: SelectionScrollRequest) {
        guard let rowID = resultRowID(for: request.index) else {
            return
        }

        guard SelectionScrollAnimationPolicy.shouldAnimate(anchor: request.anchor) else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollTargetAnchor = request.anchor.unitPoint
                scrollTargetID = rowID
            }
            return
        }

        withAnimation(selectionScrollAnimation) {
            scrollTargetAnchor = request.anchor.unitPoint
            scrollTargetID = rowID
        }
    }

    private func resultRowID(for index: Int) -> StoneResultRow.ID? {
        if model.mode.stoneDefinition.surface.usesFileBrowser {
            guard index >= 0, index < model.fileBrowserModel.entries.count else { return nil }
            return .file(model.fileBrowserModel.entries[index].url)
        }

        return model.resultRow(at: index)?.id
    }

    private func rowTransition(for row: StoneResultRow) -> AnyTransition {
        switch row.kind {
        case .dictionary, .dictionaryHistory, .calculation, .calculationHistory, .message:
            return .opacity.combined(with: .move(edge: .top))
        case .application, .file:
            return .opacity
        }
    }

    private func toolSnapshotAnimation(for snapshot: StoneResultSnapshot) -> Animation? {
        switch ToolResultsSnapshotPolicy.animation(for: model.mode, snapshot: snapshot) {
        case .none:
            return nil
        case .subtle:
            return toolSnapshotUpdateAnimation
        }
    }

    @ViewBuilder
    private func rowIcon(for row: StoneResultRow) -> some View {
        if row.kind == .application, let iconURL = row.iconURL {
            CachedIconView(url: iconURL, cache: .applications, fallbackSymbol: "app.dashed",
                           isActive: model.isPresented, loadDelayNanoseconds: AppIconPreloadPolicy.initialDelayNanoseconds)
                .frame(width: 38, height: 38)
        } else {
            Image(systemName: row.iconSystemImage ?? toolSymbol(for: row.kind))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(toolColor(for: row.kind))
                .frame(width: 38, height: 38)
        }
    }

    private func rowTitleFont(for kind: StoneResultRow.Kind) -> Font {
        if kind == .calculation {
            return .system(size: 26, weight: .semibold, design: .rounded)
        }
        return .system(size: 18, weight: .semibold)
    }

    private func rowSubtitleFont(for kind: StoneResultRow.Kind) -> Font {
        kind == .application
            ? .system(size: 12, weight: .regular)
            : .system(size: 13)
    }

    private func toolSymbol(for kind: StoneResultRow.Kind) -> String {
        switch kind {
        case .calculation:
            return "function"
        case .calculationHistory:
            return "clock.arrow.circlepath"
        case .dictionary:
            return "text.book.closed"
        case .dictionaryHistory:
            return "clock.arrow.circlepath"
        case .message:
            return "info.circle"
        case .application:
            return "app.dashed"
        case .file:
            return "doc"
        }
    }

    private func toolColor(for kind: StoneResultRow.Kind) -> Color {
        switch kind {
        case .calculation, .calculationHistory:
            return .cyan
        case .dictionary, .dictionaryHistory:
            return .mint
        case .message:
            return .secondary
        case .application, .file:
            return .secondary
        }
    }

    private func preloadApplicationIcons() {
        iconPreloadTask?.cancel()
        iconPreloadTask = nil
        guard model.mode == .applications, model.isPresented,
              !model.isShowingSettings, !model.isShowingHelp else { return }
        let urls = AppIconPreloadPolicy.preloadURLs(for: model.filteredIconURLs)
        guard !urls.isEmpty else { return }

        iconPreloadTask = Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: AppIconPreloadPolicy.initialDelayNanoseconds)
            guard !Task.isCancelled else { return }

            for (index, url) in urls.enumerated() {
                if Task.isCancelled { return }
                _ = await IconCache.applications.icon(for: url)
                if index == AppIconPreloadPolicy.initialVisibleLimit - 1 {
                    try? await Task.sleep(nanoseconds: AppIconPreloadPolicy.tailDelayNanoseconds)
                }
                if AppIconPreloadPolicy.shouldYield(afterLoadingItemAt: index) {
                    await Task.yield()
                }
            }
        }
    }
}

@available(macOS 26.0, *)
enum LauncherVisualStyle {
    static let inputSurfaceOpacity = 0.01
    static let windowCornerRadius: CGFloat = 30
    static let aetherContentSpacing: CGFloat = 14
    static let paneContentSpacing: CGFloat = 12
    static let resultsPaneCornerRadius: CGFloat = 24
    static let resultsPaneContentInset: CGFloat = 12
    static let resultsPaneModeTintOpacity = 0.08
    static let rowFill = Color(nsColor: .windowBackgroundColor)
    static let selectionFill = Color(nsColor: .selectedContentBackgroundColor)
    static let surfaceRim = Color(nsColor: .separatorColor)
    static let resultsPaneRim = Color(nsColor: .separatorColor)
    static let selectionRim = Color(nsColor: .selectedContentBackgroundColor)
    static let actionRim = Color(nsColor: .separatorColor)

}

@available(macOS 26.0, *)
struct LauncherPinnedBorderPolicy {
    static func lineWidth(isPinned: Bool) -> CGFloat {
        isPinned ? 3 : 1
    }

    static func color(isPinned: Bool) -> Color {
        isPinned
            ? Color.accentColor.opacity(0.68)
            : LauncherVisualStyle.resultsPaneRim.opacity(0.24)
    }
}

@available(macOS 26.0, *)
private extension SelectionScrollAnchor {
    var unitPoint: UnitPoint? {
        switch self {
        case .nearest:
            return nil
        case .top:
            return UnitPoint(x: 0.5, y: 0.08)
        case .bottom:
            return UnitPoint(x: 0.5, y: 0.92)
        }
    }
}

@available(macOS 26.0, *)
private extension View {
    func launcherActionButtonRim() -> some View {
        self.overlay {
            Circle()
                .strokeBorder(LauncherVisualStyle.actionRim.opacity(0.34), lineWidth: 1)
        }
    }
}

@available(macOS 26.0, *)
struct AppIconPreloadPolicy {
    static let initialVisibleLimit = 16
    static let preloadLimit = 32
    static let initialDelayNanoseconds: UInt64 = 150_000_000
    static let tailDelayNanoseconds: UInt64 = 250_000_000
    static let yieldStride = 8

    static func preloadURLs(for items: [LaunchItem]) -> [URL] {
        Array(items.prefix(preloadLimit).map(\.url))
    }

    static func preloadURLs(for urls: [URL]) -> [URL] {
        Array(urls.prefix(preloadLimit))
    }

    static func shouldYield(afterLoadingItemAt index: Int) -> Bool {
        (index + 1) % yieldStride == 0
    }
}
