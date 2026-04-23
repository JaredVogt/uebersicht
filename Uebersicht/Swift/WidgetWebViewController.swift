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
    private var displayLink: CADisplayLink?

    // Single configuration shared across all widgets so they live in the same
    // process pool / data store (keeps cookies, service workers, IndexedDB in
    // sync between widgets).
    private static let sharedConfig: WKWebViewConfiguration = buildConfig()

    // MARK: - Init

    @objc(initWithFrame:)
    public init(frame: NSRect) {
        super.init()
        view = makeWebView(frame: frame)
        startDisplayLinkIfNeeded()
    }

    /// Pins a `CADisplayLink` to the WebView so WebKit keeps servicing its
    /// render + rAF pipeline at the display's native refresh rate even when
    /// the Übersicht window is fully occluded by other app windows.
    ///
    /// Why this is needed: Übersicht's windows sit at `kCGNormalWindowLevel-1`
    /// (foreground) or `kCGDesktopWindowLevel` (background). The moment an
    /// opaque app window covers the desktop, macOS marks these windows as
    /// occluded and WebKit throttles `requestAnimationFrame` to ~30 Hz or
    /// 1 Hz. Widget animations (ants, bouncing-dot) visibly stutter whenever
    /// the user isn't looking at the desktop — which is most of the time.
    ///
    /// The fix: drive an empty `evaluateJavaScript` call on every display
    /// tick. That wakes the WebView's main thread and forces its next rAF
    /// frame to schedule. CADisplayLink on macOS syncs to the display's
    /// actual refresh rate (60/120/144 Hz), so this costs exactly one frame
    /// slot per frame the display was going to render anyway.
    ///
    /// CADisplayLink on the AppKit side requires macOS 14+; the project's
    /// deployment target is already 14.0 so no fallback is needed.
    private func startDisplayLinkIfNeeded() {
        guard let webView = view as? WKWebView else { return }
        let link = webView.displayLink(target: self, selector: #selector(tickDisplay(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tickDisplay(_ sender: CADisplayLink) {
        // `evaluateJavaScript` with a no-op expression is the cheapest way to
        // force WebKit to run one iteration of its event loop on the web
        // content process. Any side-effect-free JS works; empty string would
        // too but some WebKit builds short-circuit on literal empty input.
        (view as? WKWebView)?.evaluateJavaScript("0;", completionHandler: nil)
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
        displayLink?.invalidate()
        displayLink = nil
        guard let webView = view as? WKWebView else { return }
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        view = nil
    }

    // MARK: - Build

    private func makeWebView(frame: NSRect) -> WKWebView {
        let webView = WidgetWebView(frame: frame, configuration: Self.sharedConfig)
        #if DEBUG
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
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

        // Console bridge: forward browser console.{log,warn,error} + uncaught
        // errors to NSLog so headless sessions can see JS runtime state
        // without attaching Safari's Web Inspector. Release builds skip it
        // entirely — the per-log string alloc + IPC hop is pure overhead
        // when nothing reads NSLog.
        #if DEBUG
        controller.add(ConsoleMessageHandler(), name: "ubConsole")
        controller.addUserScript(WKUserScript(
            source: """
            (function(){
              function fwd(level, args) {
                try {
                  window.webkit.messageHandlers.ubConsole.postMessage({
                    level: level,
                    msg: Array.from(args).map(function(a){
                      try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
                      catch(e) { return String(a); }
                    }).join(' ')
                  });
                } catch(_) {}
              }
              ['log','warn','error','info'].forEach(function(k){
                var orig = console[k].bind(console);
                console[k] = function(){ fwd(k, arguments); orig.apply(null, arguments); };
              });
              window.addEventListener('error', function(e){
                fwd('error', ['uncaught', e.message, 'at', e.filename+':'+e.lineno+':'+e.colno]);
              });
              window.addEventListener('unhandledrejection', function(e){
                var r = e.reason;
                var detail;
                if (r && r.stack) detail = r.message + '\\n' + r.stack;
                else if (r && r.message) detail = r.message;
                else if (r && r.type) detail = 'event:' + r.type;
                else { try { detail = JSON.stringify(r); } catch(_){ detail = String(r); } }
                fwd('error', ['unhandled rejection:', detail]);
              });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        #endif

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

/// Forwards `console.log`/`console.error`/uncaught errors from the WebView
/// into `NSLog` so we can diagnose rendering issues without attaching a
/// Web Inspector. Installed by the user script in `buildConfig()`.
@MainActor
final class ConsoleMessageHandler: NSObject, WKScriptMessageHandler {
    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return }
            let level = body["level"] as? String ?? "log"
            let msg = body["msg"] as? String ?? ""
            NSLog("[webview %@] %@", level, msg)
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
