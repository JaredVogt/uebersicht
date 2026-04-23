import AppKit
import WebKit

/// Hosts a single widget's WKWebView inside a `UBWindow`.
///
/// Drop-in replacement for the Obj-C `UBWebViewController`. Kept under the
/// `UBWebViewController` runtime name so `UBWindow.m` continues to work.
///
/// This controller does three things:
///   1. Owns the WKWebView and its user-content controller.
///   2. Installs the geolocation + `process.argv` user scripts so legacy
///      widgets keep running.
///   3. Handles the `uebersicht` script-message channel (mouse-enter/leave
///      for widgets with `.draggable` content).
///
/// Prior to this rewrite the controller reached into private WebKit headers
/// (`WKView`, `WKPage`, `WKInspector`, `WKWebViewInternal`). Those are gone;
/// `WKWebView.isInspectable = true` is set at creation and developers use
/// Safari's Develop menu to open the inspector.
@objc(UBWebViewController)
@MainActor
public final class WidgetWebViewController: NSObject {

    @objc public private(set) var view: NSView!
    private var url: URL?

    // Single configuration shared across all widgets so they live in the same
    // process pool / data store (keeps cookies, service workers, IndexedDB in
    // sync between widgets).
    private static let sharedConfig: WKWebViewConfiguration = buildConfig()

    // MARK: - Init

    @objc(initWithFrame:)
    public init(frame: NSRect) {
        super.init()
        view = makeWebView(frame: frame)
    }

    // MARK: - Obj-C surface

    @objc(load:)
    public func load(_ newUrl: URL) {
        guard let window = view.window as? UBWindow else {
            url = newUrl
            return
        }
        switch window.windowType {
        case .agnostic:
            url = newUrl
        case .background:
            url = newUrl.appendingPathComponent("background")
        case .foreground:
            url = newUrl.appendingPathComponent("foreground")
        @unknown default:
            url = newUrl
        }
        guard let url, let webView = view as? WKWebView else { return }
        webView.load(URLRequest(url: url))
    }

    @objc public func reload() {
        (view as? WKWebView)?.reloadFromOrigin()
    }

    @objc public func redraw() {
        guard let webView = view as? WKWebView else { return }
        let js = """
        document.documentElement.style.transform = 'scale(1)';
        requestAnimationFrame(function() {
            document.documentElement.style.transform = '';
        });
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc public func destroy() {
        guard let webView = view as? WKWebView else { return }
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        view = nil
    }

    // MARK: - Build

    private func makeWebView(frame: NSRect) -> WKWebView {
        let webView = WidgetWebView(frame: frame, configuration: Self.sharedConfig)
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView.navigationDelegate = self
        return webView
    }

    private static func buildConfig() -> WKWebViewConfiguration {
        let controller = WKUserContentController()

        // Geolocation bridge.
        let geolocation = Geolocation()
        controller.add(geolocation, name: "geolocation")
        if
            let url = Bundle.main.url(forResource: "geolocation", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        {
            controller.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }

        // Legacy widget compat: `process.argv[0]` used to point at localnode.
        if let nodePath = Bundle.main.path(forResource: "localnode", ofType: nil) {
            let escaped = nodePath.replacingOccurrences(of: " ", with: #"\\ "#)
            controller.addUserScript(WKUserScript(
                source: "process = {argv: ['\(escaped)']};",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }

        // `uebersicht` channel: widget mouse enter/leave.
        controller.add(UebersichtMessageHandler(), name: "uebersicht")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        return config
    }
}

// MARK: - WKNavigationDelegate

extension WidgetWebViewController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("loaded %@", webView.url?.absoluteString ?? "")
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        handleLoadError(error)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        handleLoadError(error)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        if navigationAction.request.url == url {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           let target = navigationAction.request.url {
            NSWorkspace.shared.open(target)
        }
        decisionHandler(.cancel)
    }

    private func handleLoadError(_ error: any Error) {
        NSLog("Error loading webview: %@", error as NSError)
        guard let url else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.load(url)
        }
    }
}

/// Handles the `uebersicht` script-message channel used by widgets to flag
/// when the cursor enters/leaves their bounds. We toggle
/// `ignoresMouseEvents` on the host window so that widgets can opt into
/// interactivity while the rest of the desktop stays passthrough.
@MainActor
final class UebersichtMessageHandler: NSObject, WKScriptMessageHandler {
    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? String, let window = message.webView?.window else { return }
            switch body {
            case "widgetEnter":
                window.ignoresMouseEvents = false
            case "widgetLeave":
                window.ignoresMouseEvents = true
            default:
                break
            }
        }
    }
}
