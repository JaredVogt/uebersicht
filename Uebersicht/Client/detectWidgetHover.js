// Event-driven hover bridge. Fires `widgetEnter`/`widgetLeave` to the host
// whenever the pointer crosses from the container to a widget or back out.
// `pointerover`/`pointerout` bubble from nested SVG nodes, so widgets with
// complex DOM (ants, etc.) work without attaching listeners inside them.
export default function detectWidgetHover(containerEl) {
  let insideWidget = false;

  window.addEventListener('pointerover', (e) => {
    if (insideWidget || e.target === containerEl) return;
    insideWidget = true;
    window.webkit?.messageHandlers?.uebersicht?.postMessage('widgetEnter');
  }, { passive: true });

  window.addEventListener('pointerout', (e) => {
    if (!insideWidget) return;
    // `relatedTarget` is the node the pointer entered next. Null means the
    // pointer left the document entirely; `containerEl` means it hit the
    // bare container (no widget beneath). Either way we're no longer over
    // a widget.
    if (e.relatedTarget === null || e.relatedTarget === containerEl) {
      insideWidget = false;
      window.webkit?.messageHandlers?.uebersicht?.postMessage('widgetLeave');
    }
  }, { passive: true });
}
