// Wraps a single widget implementation and runs its command loop +
// virtual-DOM render cycle. Each widget gets its own instance; the container
// `render.js` decides when to mount/unmount one.
//
// `implementation.render()` returns a vnode tree. We pass `html` (= Preact's
// `h`) to widgets both as a global for classic-style widgets and via the
// `uebersicht` module for modern JSX widgets. Preact's `render` replaces
// React-DOM's render; calling signature differs (`render(vnode, parent)`
// vs `ReactDom.render(vnode, parent)`), but the effect is the same.

import { h, Fragment, render as preactRender } from 'preact';
import { css } from '@emotion/css';
import RenderLoop from './renderLoop.js';
import Timer from './Timer.js';
import runShellCommand from './runShellCommand.js';
import ErrorDetails from './ErrorDetails/index.js';

// Widgets bundled with the JSXTransformer classic transform emit
// `html(...)` and `html(Fragment, ...)` calls. Expose both globally so
// existing widgets work unchanged.
if (typeof window !== 'undefined') {
  window.html = h;
  window.Fragment = Fragment;
}

const defaults = {
  id: 'widget',
  refreshFrequency: 1000,
  init() {},
  render(props) {
    return h('div', null, props.error ? String(props.error) : props.output);
  },
  updateState(event) {
    return { error: event.error, output: event.output };
  },
  initialState: { output: '' },
};

export default function VirtualDomWidget(widgetObject) {
  const api = {};
  let implementation;
  let contentEl;
  let commandLoop;
  let renderLoop;
  let currentError;

  function init(widget) {
    currentError = widget.error
      ? (typeof widget.error === 'string' ? JSON.parse(widget.error) : widget.error)
      : undefined;
    implementation = Object.create(defaults);
    Object.assign(implementation, widget.implementation || {}, { id: widget.id });
    return api;
  }

  function start() {
    if (currentError) {
      renderErrorDetails(currentError);
      return;
    }
    if (renderLoop) {
      renderLoop.update(renderLoop.state); // force redraw
    } else {
      renderLoop = RenderLoop(implementation.initialState, render);
    }
    run();
  }

  function run() {
    implementation.init(dispatch);
    if (!implementation.command) return;
    commandLoop = Timer()
      .start()
      .map((done) => {
        execWidgetCommand()
          .then(commandCompleted)
          .catch(commandErrored)
          .then(() => done(implementation.refreshFrequency));
      });
  }

  function commandCompleted(output) {
    dispatch({ type: 'UB/COMMAND_RAN', output });
  }

  function commandErrored(error) {
    dispatch({ type: 'UB/COMMAND_RAN', error });
  }

  function runCommandFunction(command) {
    try {
      return command.apply(implementation, [dispatch]);
    } catch (err) {
      handleError(err);
    }
  }

  function execWidgetCommand() {
    const { command } = implementation;
    if (typeof command === 'function')
      return Promise.resolve(runCommandFunction(command));
    if (typeof command === 'string')
      return runShellCommand(command, undefined, implementation.id);
    return Promise.resolve();
  }

  function dispatch(event) {
    // Widget has been destroyed but a RAF/setInterval the widget set up
    // directly is still firing. Silently no-op so we don't route through
    // handleError → fetchErrorDetails (one fetch per leaked frame).
    if (!renderLoop) return;
    try {
      const nextState = implementation.updateState(event, renderLoop.state);
      renderLoop.update(nextState);
    } catch (err) {
      handleError(err);
    }
  }

  function fetchErrorDetails(err) {
    return fetch(
      `/widgets/${widgetObject.id}?line=${err.line}&column=${err.column}`,
    ).then((res) => res.json());
  }

  function render(state) {
    try {
      preactRender(implementation.render(state, dispatch), contentEl);
    } catch (err) {
      handleError(err);
    }
  }

  function handleError(err) {
    currentError = err;
    commandLoop && commandLoop.stop();
    fetchErrorDetails(err).then((details) => {
      if (err !== currentError) return;
      renderErrorDetails(Object.assign({ message: err.message }, details));
    });
  }

  function renderErrorDetails(details) {
    preactRender(h(ErrorDetails, details), contentEl);
  }

  api.create = function create() {
    contentEl = document.createElement('div');
    contentEl.id = implementation.id;
    contentEl.classList.add('widget');
    if (implementation.className) {
      contentEl.classList.add(css(implementation.className));
    }
    document.body.appendChild(contentEl);
    start();
    return contentEl;
  };

  api.destroy = function destroy() {
    commandLoop && commandLoop.stop();
    if (contentEl && contentEl.parentNode) {
      contentEl.parentNode.removeChild(contentEl);
    }
    renderLoop = null;
    contentEl = null;
    currentError = null;
  };

  api.update = function update(newImplementation) {
    commandLoop && commandLoop.stop();
    if (implementation.className) {
      contentEl.classList.remove(css(implementation.className));
    }
    init(newImplementation);
    if (implementation.className) {
      contentEl.classList.add(css(implementation.className));
    }
    start();
  };

  api.forceRefresh = function forceRefresh() {
    commandLoop && commandLoop.forceTick();
  };

  return init(widgetObject);
}
