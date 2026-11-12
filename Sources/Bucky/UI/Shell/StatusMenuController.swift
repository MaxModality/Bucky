import AppKit

@MainActor
final class StatusMenuController: NSObject {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let openAction: @MainActor () -> Void
    private let reindexAction: @MainActor () -> Void
    private let settingsAction: @MainActor () -> Void

    init(
        openAction: @escaping @MainActor () -> Void,
        reindexAction: @escaping @MainActor () -> Void,
        settingsAction: @escaping @MainActor () -> Void
    ) {
        self.openAction = openAction
        self.reindexAction = reindexAction
        self.settingsAction = settingsAction
        super.init()
        buildMenu()
    }

    private func buildMenu() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Bucky")
            image?.isTemplate = true
            image?.size = Self.menuBarIconSize
            Self.configureButton(button, image: image)
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Bucky", action: #selector(open), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let reindexItem = NSMenuItem(title: "Reindex Applications", action: #selector(reindex), keyEquivalent: "")
        reindexItem.target = self
        menu.addItem(reindexItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(settings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Bucky", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: "Bucky \(Self.versionString)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        statusItem.menu = menu
        statusItem.isVisible = true
    }

    internal static func configureButton(_ button: NSStatusBarButton, image: NSImage?) {
        button.image = image
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = image == nil ? .noImage : .imageOnly
        button.title = image == nil ? "B" : ""
        button.toolTip = "Bucky"
    }

    private static let menuBarIconSize = NSSize(width: 16, height: 16)

    private static var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown version"
    }

    @objc private func open() {
        openAction()
    }

    @objc private func reindex() {
        reindexAction()
    }

    @objc private func settings() {
        settingsAction()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
