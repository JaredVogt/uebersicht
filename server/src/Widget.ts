import ClassicWidget from './ClassicWidget';
import VirtualDomWidget from './VirtualDomWidget';

export default function Widget(widget: any) {
  let api;

  if (/\.jsx$/.test(widget.filePath)) {
    api = VirtualDomWidget(widget);
  } else {
    api = ClassicWidget(widget);
  }

  return api;
}
