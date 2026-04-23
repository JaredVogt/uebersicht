import VirtualDomWidget from './VirtualDomWidget.js';

// CoffeeScript `ClassicWidget` is dropped as part of the modernization. If
// we somehow see a non-`.jsx` widget, log once and fall back to the VDOM
// renderer so we still render *something* using its `render`/`command`.
export default function Widget(widget) {
  if (!/\.jsx$/.test(widget.filePath)) {
    console.warn(
      `Uebersicht: non-JSX widget "${widget.id}" — classic widgets are ` +
      `no longer supported. Rename the file to .jsx.`
    );
  }
  return VirtualDomWidget(widget);
}
