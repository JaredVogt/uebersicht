import {css} from 'emotion';
import RenderLoop from './renderLoop';
import Timer from './Timer';
import runShellCommand from './runShellCommand';
import ReactDom from 'react-dom';
import React from 'react';
import ErrorDetails from './ErrorDetails';
const html = React.createElement;
window.html = html;

const defaults = {
  id: 'widget',
  refreshFrequency: 1000,
  init: function init() {},
  render: function render(props: any) {
    return html('div', null, props.error ? String(props.error) : props.output);
  },
  updateState: function updateState(event: any) {
    return {error: event.error, output: event.output};
  },
  initialState: {output: ''},
};

export default function VirtualDomWidget(widgetObject: any) {
  const api: any = {};
  let implementation: any;
  let contentEl: any;
  let commandLoop: any;
  let renderLoop: any;
  let currentError: any;

  function init(widget: any) {
    currentError = widget.error ? JSON.parse(widget.error) : undefined;
    implementation = Object.create(defaults);
    Object.assign(implementation, widget.implementation || {}, {id: widget.id});
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
      .map((done: any) => {
        execWidgetCommand()
          .then(commandCompleted)
          .catch(commandErrored)
          .then(() => done(implementation.refreshFrequency));
      });
  }

  function commandCompleted(output: any) {
    dispatch({type: 'UB/COMMAND_RAN', output});
  }

  function commandErrored(error: any) {
    dispatch({type: 'UB/COMMAND_RAN', error});
  }

  const runCommandFunction = (command: any) => {
    try {
      return command.apply(implementation, [dispatch]);
    } catch (err) {
      handleError(err);
    }
  };

  function execWidgetCommand() {
    const {command} = implementation;
    if (typeof command === 'function')
      return Promise.resolve(runCommandFunction(command));
    else if (typeof command === 'string')
      return runShellCommand(command, undefined, implementation.id);
    else return Promise.resolve();
  }

  function dispatch(event: any) {
    // Widget has been destroyed (e.g. user hid it) but a RAF/setInterval the
    // widget set up directly is still firing. Silently no-op so we don't
    // route through handleError → fetchErrorDetails, which would make a
    // fetch on every leaked frame and saturate the WebKit Networking IPC.
    if (!renderLoop) return;
    try {
      const nextState = implementation.updateState(event, renderLoop.state);
      renderLoop.update(nextState);
    } catch (err) {
      handleError(err);
    }
  }

  function fetchErrorDetails(err: any) {
    return fetch(
      `/widgets/${widgetObject.id}?line=${err.line}&column=${err.column}`,
    ).then((res) => res.json());
  }

  function render(state: any) {
    try {
      ReactDom.render(implementation.render(state, dispatch), contentEl);
    } catch (err) {
      handleError(err);
    }
  }

  function handleError(err: any) {
    currentError = err;
    commandLoop && commandLoop.stop();
    fetchErrorDetails(err).then((details: any) => {
      if (err !== currentError) return;
      renderErrorDetails(Object.assign({message: err.message}, details));
    });
  }

  function renderErrorDetails(details: any) {
    ReactDom.render(html(ErrorDetails, details), contentEl);
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

  api.update = function update(newImplementation: any) {
    commandLoop && commandLoop.stop();
    contentEl.classList.remove(css(implementation.className));
    init(newImplementation);
    if (implementation.className) {
      contentEl.classList.add(css(implementation.className));
    }
    start();
  };

  api.forceRefresh = function forceRefresh() {
    commandLoop.forceTick();
  };

  return init(widgetObject);
}
