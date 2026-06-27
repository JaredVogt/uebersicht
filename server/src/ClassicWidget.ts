import $ from 'jquery';
(window as any).jQuery = $;

import Timer from './Timer';
import runCommand from './runCommand';
import runShellCommand from './runShellCommand';

const defaults = {
  id: 'widget',
  refreshFrequency: 1000,
  render: (output: any) => output,
  afterRender: () => {},
};

// This is a wrapper (something like a base class), around the
// specific implementation of a widget.
export default function ClassicWidget(widgetObject: any) {
  const api: any = {};
  const internalApi: any = {};

  let el: HTMLElement | null = null;
  let contentEl: HTMLElement | null = null;
  let rendered = false;
  let commandLoop: any = null;
  let implementation: any = {};
  let currentError: any = null;

  const init = (widget: any) => {
    currentError = widget.error ? JSON.parse(widget.error) : null;
    implementation = widget.implementation || {};
    implementation.id = widget.id;

    for (const k of Object.keys(defaults)) {
      if (implementation[k] == null) implementation[k] = (defaults as any)[k];
    }
    for (const k of Object.keys(internalApi)) {
      if (!implementation[k]) implementation[k] = internalApi[k];
    }

    commandLoop = Timer().map((done: any) => {
      runCommand(implementation, (err: any, output: any) => {
        redraw(err, output);
        done(implementation.refreshFrequency);
      });
    });

    return api;
  };

  // renders and returns the widget's dom element
  api.create = () => {
    el = document.createElement('div');
    contentEl = document.createElement('div');
    contentEl.id = implementation.id;
    contentEl.className = 'widget';
    el.innerHTML = `<style>${implementation.css}</style>\n`;
    el.appendChild(contentEl);

    start();
    return el;
  };

  api.destroy = () => {
    stop();
    if (el == null) return;
    if (el.parentNode) el.parentNode.removeChild(el);
    el = null;
    contentEl = null;
    rendered = false;
  };

  api.update = (newImplementation: any) => {
    const parentEl = el!.parentNode!;
    api.destroy();
    init(newImplementation);
    parentEl.appendChild(api.create());
  };

  api.domEl = () => el;

  api.isRendered = () => !!el;

  api.internalApi = () => internalApi;

  api.implementation = () => implementation;

  api.forceRefresh = () => internalApi.refresh();

  // starts the widget refresh cycle
  function start() {
    if (currentError) return redraw(currentError);
    commandLoop.start();
  }
  internalApi.start = start;

  // stops the widget refresh cycle
  function stop() {
    commandLoop.stop();
  }
  internalApi.stop = stop;

  // run widget command and redraw the widget
  function refresh() {
    if (implementation.command == null) return redraw();
    commandLoop.forceTick();
  }
  internalApi.refresh = refresh;

  // runs command in the shell and calls callback with the result (err, stdout)
  internalApi.run = (command: any, cb: any) => runShellCommand(command, cb);

  function redraw(error?: any, output?: any) {
    if (error) {
      contentEl!.style.fontFamily = 'monospace';
      contentEl!.style.fontSize = '12px';
      contentEl!.style.whiteSpace = 'pre';
      contentEl!.style.background = '#fff';
      contentEl!.style.padding = '20px';
      contentEl!.innerHTML = error.message + '\n' + (error.lines || '');
      console.error(`${implementation.id}:`, error);
      rendered = false;
      return;
    }

    contentEl!.style.fontFamily = '';
    contentEl!.style.fontSize = '';
    contentEl!.style.whiteSpace = '';
    contentEl!.style.background = '';
    contentEl!.style.padding = '';

    try {
      renderOutput(output);
    } catch (e) {
      redraw(e);
    }
  }

  function renderOutput(output: any) {
    if (implementation.update != null && rendered) {
      implementation.update(output, contentEl);
    } else {
      contentEl!.innerHTML = implementation.render(output);
      loadScripts(contentEl!);

      implementation.afterRender(contentEl);
      rendered = true;
      if (implementation.update != null) implementation.update(output, contentEl);
    }
  }

  function loadScripts(domEl: HTMLElement) {
    for (const script of Array.from(domEl.getElementsByTagName('script'))) {
      const s = document.createElement('script');
      s.src = script.src;
      domEl.replaceChild(s, script);
    }
  }

  return init(widgetObject);
}
