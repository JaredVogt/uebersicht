import AppKit
import Sparkle

/// Programmatically builds the NSMenu that lives behind the menu-bar status
/// item. Replaces the XIB-provided `statusBarMenu` outlet so `MainMenu.xib`
/// can be deleted. `UBWidgetsController` still mutates an NSMenu, so the
/// runtime shape here stays identical to what the XIB produced — same order,
/// same titles, same selectors, same "Check for Updates…" anchor that
/// `UBWidgetsController.indexOfWidgetMenuItems:` searches for.
///
/// Sparkle: the XIB used to instantiate `SUUpdater` as a root object and wire
/// `checkForUpdates:` to it. We now construct `SPUStandardUpdaterController`
/// programmatically (the Sparkle 2 way) and target the menu item at it.
@MainActor
@objc(UBStatusBarMenuBuilder)
public final class StatusBarMenuBuilder: NSObject {

    @objc public let menu: NSMenu
    private let updaterController: SPUStandardUpdaterController

    @objc(buildForDelegate:)
    public static func build(forDelegate delegate: AnyObject) -> StatusBarMenuBuilder {
        StatusBarMenuBuilder(delegate: delegate)
    }

    private init(delegate: AnyObject) {
        self.menu = NSMenu(title: "Uebersicht")
        self.menu.autoenablesItems = false
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        populate(delegate: delegate)
    }

    private func populate(delegate: AnyObject) {
        add(title: "About Uebersicht",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            target: NSApp)

        add(title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            target: updaterController)

        menu.addItem(.separator())

        add(title: "Open Widgets Folder",
            action: Selector(("openWidgetDir:")),
            target: delegate)

        add(title: "Visit Widget Gallery",
            action: Selector(("visitWidgetGallery:")),
            target: delegate)

        menu.addItem(.separator())

        add(title: "Show Debug Console",
            action: Selector(("showDebugConsole:")),
            target: delegate)

        add(title: "Refresh All Widgets",
            action: Selector(("refreshWidgets:")),
            target: delegate)

        menu.addItem(.separator())

        add(title: "Preferences...",
            action: Selector(("showPreferences:")),
            target: delegate,
            keyEquivalent: ",")

        menu.addItem(.separator())

        add(title: "Quit Uebersicht",
            action: #selector(NSApplication.terminate(_:)),
            target: NSApp,
            keyEquivalent: "q")
    }

    @discardableResult
    private func add(
        title: String,
        action: Selector,
        target: AnyObject,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        menu.addItem(item)
        return item
    }
}
