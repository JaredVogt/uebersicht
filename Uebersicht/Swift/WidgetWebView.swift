import AppKit
import WebKit

/// WKWebView subclass used for rendering widgets on the desktop.
///
/// Replaces the Obj-C `UBWebView` (with the same Obj-C runtime name so
/// existing callers that look up subviews by class still work).
///
/// Two behaviors diverge from stock WKWebView:
/// - `acceptsFirstMouse(for:)` is `true` so widgets respond to clicks even
///   when the app isn't active — important for desktop widgets that aren't
///   supposed to steal focus.
/// - Transparent background via CSS flows through. We configure transparency
///   at the layer + WebKit config level so widgets with `body{background:transparent}`
///   composite correctly against the desktop.
@objc(UBWebView)
public final class WidgetWebView: WKWebView {

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        applyTransparentBackground()
        #if DEBUG
        isInspectable = true
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func applyTransparentBackground() {
        underPageBackgroundColor = .clear
        // Historically the only reliable way to get a transparent WKWebView
        // background on macOS. Still required as of macOS 15 — there is no
        // official replacement and Apple's DTS continues to recommend it.
        setValue(false, forKey: "drawsBackground")
    }
}
