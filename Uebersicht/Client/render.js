import Widget from './Widget.js';

const rendered = {};

function isVisibleOnScreen(widgetId, screenId, state) {
  const settings = state.settings[widgetId] || {};
  if (settings.hidden) return false;
  if (settings.showOnAllScreens || settings.showOnAllScreens === undefined) return true;
  if (settings.showOnMainScreen) return state.screens.indexOf(screenId) === 0;
  if (settings.showOnSelectedScreens) {
    return (settings.screens || []).indexOf(screenId) !== -1;
  }
  return false;
}

function isInBackground(widgetId, state) {
  const settings = state.settings[widgetId] || {};
  return settings.inBackground === true;
}

function renderWidget(widget, domEl) {
  const prevRendered = rendered[widget.id];
  if (prevRendered && prevRendered.widget.mtime === widget.mtime) {
    return;
  }
  if (prevRendered) {
    prevRendered.instance.update(widget);
    prevRendered.widget = widget;
    return;
  }
  console.log('[ub] mount', widget.id);
  const instance = Widget(widget);
  domEl.appendChild(instance.create());
  rendered[widget.id] = { instance, widget };
}

function destroyWidget(id) {
  rendered[id].instance.destroy();
  delete rendered[id];
}

export default function render(state, screen, domEl, dispatch) {
  const remaining = Object.keys(rendered);

  for (const id in state.widgets) {
    const widget = state.widgets[id];
    if (!isVisibleOnScreen(id, screen.id, state)) continue;
    if (
      screen.layer &&
      (screen.layer === 'background') !== isInBackground(id, state)
    ) continue;
    if (widget.error || widget.implementation) {
      renderWidget(widget, domEl, dispatch);
    }
    const idx = remaining.indexOf(widget.id);
    if (idx > -1) remaining.splice(idx, 1);
  }

  remaining.forEach((obsolete) => destroyWidget(obsolete));
}

export { rendered };
