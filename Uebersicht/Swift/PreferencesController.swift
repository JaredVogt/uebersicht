import AppKit
import SwiftUI
import ServiceManagement

/// Swift + SwiftUI replacement for `UBPreferencesController` (and its .xib).
/// Kept under the `UBPreferencesController` runtime name so
/// `UBAppDelegate.m` and `UBWidgetsController.m` don't need to change.
///
/// Modernization wins over the old Obj-C implementation:
///   • `SMAppService` replaces the `LSSharedFileList*` API (deprecated in
///     10.11, long gone from any supported macOS).
///   • `Codable` in `UserDefaults` replaces the `NSKeyedArchiver` bookmarks
///     dance (the legacy `archivedDataWithRootObject:` is deprecated).
///   • The UI is a SwiftUI view hosted via `NSHostingController`; the XIB
///     (and its fragile key-value bindings that brought the whole app down
///     when XcodeGen clobbered Info.plist earlier in this series) is gone.
@MainActor
@objc(UBPreferencesController)
public final class PreferencesController: NSWindowController {

    public static let shared = PreferencesController()

    /// NSWidgetInteractionEnabledNotification-style KVO hook — UBWidgetsController
    /// reads this via `preferences.enableInteraction` and expects it to be
    /// KVO-observable. @objc dynamic preserves that.
    @objc public dynamic var enableInteraction: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enableInteraction) as? Bool ?? true }
        set {
            willChangeValue(for: \.enableInteraction)
            UserDefaults.standard.set(newValue, forKey: Keys.enableInteraction)
            didChangeValue(for: \.enableInteraction)
            NotificationCenter.default.post(name: .ubInteractionDidChange, object: self)
        }
    }

    /// Where widgets live. Bookmark data preserved across app launches /
    /// sandboxed moves. Default: ~/Library/Application Support/Uebersicht/widgets.
    @objc public dynamic var widgetDir: URL {
        get {
            if let data = UserDefaults.standard.data(forKey: Keys.widgetDir),
               let url = try? URL(
                    resolvingBookmarkData: data,
                    options: [.withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &bookmarkStale
               ) {
                return url
            }
            return PreferencesController.ensuredDefaultWidgetDir()
        }
        set {
            willChangeValue(for: \.widgetDir)
            if let data = try? newValue.bookmarkData() {
                UserDefaults.standard.set(data, forKey: Keys.widgetDir)
            }
            didChangeValue(for: \.widgetDir)
            NotificationCenter.default.post(name: .ubWidgetDirDidChange, object: self)
        }
    }

    @objc public dynamic var loginShell: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.loginShell) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.loginShell)
            NotificationCenter.default.post(name: .ubLoginShellDidChange, object: self)
        }
    }

    @objc public dynamic var startAtLogin: Bool {
        get {
            if #available(macOS 13, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }
        set {
            if #available(macOS 13, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("SMAppService error: %@", String(describing: error))
                }
            }
        }
    }

    // MARK: - Lifecycle

    private var bookmarkStale = false

    public init() {
        super.init(window: nil)
        let view = PreferencesView(controller: self)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 260))
        window.isRestorable = false
        window.center()
        self.window = window
        self.shouldCascadeWindows = false
        _ = PreferencesController.ensuredDefaultWidgetDir()  // make sure it exists
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("nib-less") }

    // MARK: - Defaults bootstrap

    @discardableResult
    static func ensuredDefaultWidgetDir() -> URL {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let widgetDir = supportDir
            .appendingPathComponent("Uebersicht", isDirectory: true)
            .appendingPathComponent("widgets", isDirectory: true)

        if !FileManager.default.fileExists(atPath: widgetDir.path) {
            try? FileManager.default.createDirectory(
                at: widgetDir,
                withIntermediateDirectories: true
            )
            // Seed with GettingStarted widget so the first-run is non-empty.
            if let getting = Bundle.main.url(forResource: "GettingStarted", withExtension: "jsx") {
                try? FileManager.default.copyItem(
                    at: getting,
                    to: widgetDir.appendingPathComponent("GettingStarted.jsx")
                )
            }
            if let logo = Bundle.main.url(forResource: "uebersicht-logo", withExtension: "png") {
                try? FileManager.default.copyItem(
                    at: logo,
                    to: widgetDir.appendingPathComponent("logo.png")
                )
            }
        }
        return widgetDir
    }

    enum Keys {
        static let enableInteraction = "enableInteraction"
        static let widgetDir = "widgetDirectoryBookmark"
        static let loginShell = "loginShell"
    }
}

extension Notification.Name {
    static let ubInteractionDidChange = Notification.Name("UBInteractionDidChange")
    static let ubWidgetDirDidChange = Notification.Name("UBWidgetDirDidChange")
    static let ubLoginShellDidChange = Notification.Name("UBLoginShellDidChange")
}

// MARK: - SwiftUI view

private struct PreferencesView: View {
    weak var controller: PreferencesController?

    @State private var enableInteraction: Bool = true
    @State private var loginShell: Bool = false
    @State private var startAtLogin: Bool = false
    @State private var widgetDir: URL = URL(fileURLWithPath: NSHomeDirectory())

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Widgets folder:")
                    Spacer()
                    Text(widgetDir.path)
                        .truncationMode(.middle)
                        .frame(maxWidth: 300, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Button("Choose…", action: chooseWidgetDir)
                }
            }
            Section {
                Toggle("Enable widget interaction", isOn: $enableInteraction)
                    .onChange(of: enableInteraction) { _, value in
                        controller?.enableInteraction = value
                    }
                Toggle("Run shell commands in a login shell", isOn: $loginShell)
                    .onChange(of: loginShell) { _, value in
                        controller?.loginShell = value
                    }
                Toggle("Start at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, value in
                        controller?.startAtLogin = value
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            guard let controller else { return }
            enableInteraction = controller.enableInteraction
            loginShell = controller.loginShell
            startAtLogin = controller.startAtLogin
            widgetDir = controller.widgetDir
        }
    }

    private func chooseWidgetDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = widgetDir
        if panel.runModal() == .OK, let url = panel.url {
            controller?.widgetDir = url
            widgetDir = url
        }
    }
}
