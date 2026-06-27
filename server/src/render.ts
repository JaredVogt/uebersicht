import Widget from './Widget';
const rendered: any = {};

function matchesScreen(target: any, screenId: any, state: any) {
  const name = state.screenNames ? state.screenNames[screenId] : undefined;
  const targets = Array.isArray(target) ? target : [target];

  return targets.some(function (t: any) {
    if (t === 'main') return state.screens.indexOf(screenId) === 0;
    if (t instanceof RegExp) return name != null && t.test(name);
    return name != null && name.indexOf(t) !== -1;
  });
}

function isVisibleOnScreen(widget: any, screenId: any, state: any) {
  const settings = state.settings[widget.id] || {};
  let isVisible = false;
  const declaredScreen = widget.implementation && widget.implementation.screen;

  if (settings.hidden) {
    isVisible = false;
  } else if (!settings.userModified && declaredScreen != null) {
    // Widget targets a screen from its source and the user has not overridden
    // it from the menu, so honor the declared target.
    isVisible = matchesScreen(declaredScreen, screenId, state);
  } else if (
    settings.showOnAllScreens ||
    settings.showOnAllScreens === undefined
  ) {
    isVisible = true;
  } else if (settings.showOnMainScreen) {
    isVisible = state.screens.indexOf(screenId) === 0;
  } else if (settings.showOnSelectedScreens) {
    isVisible = (settings.screens || []).indexOf(screenId) !== -1;
  }

  return isVisible;
}

function isInBackground(widgetId: any, state: any) {
  const settings = state.settings[widgetId] || {};
  return settings.inBackground === true;
}

function renderWidget(widget: any, domEl: any, dispatch?: any) {
  const prevRendered = rendered[widget.id];

  if (prevRendered && prevRendered.widget.mtime === widget.mtime) {
    return;
  } else if (prevRendered) {
    prevRendered.instance.update(widget);
    prevRendered.widget = widget;
  } else {
    const instance = Widget(widget);
    domEl.appendChild(instance.create());
    rendered[widget.id] = {
      instance: instance,
      widget: widget,
    };
  }
}

function destroyWidget(id: any) {
  rendered[id].instance.destroy();
  delete rendered[id];
}

function render(state: any, screen: any, domEl: any, dispatch: any) {
  const remaining = Object.keys(rendered);

  for (const id in state.widgets) {
    const widget = state.widgets[id];

    if (!isVisibleOnScreen(widget, screen.id, state)) continue;

    if (
      screen.layer &&
      (screen.layer === 'background') != isInBackground(id, state)
    )
      continue;

    if (widget.error || widget.implementation)
      renderWidget(widget, domEl, dispatch);

    const idx = remaining.indexOf(widget.id);
    if (idx > -1) remaining.splice(idx, 1);
  }

  remaining.forEach((obsolete) => destroyWidget(obsolete));
}

(render as any).rendered = rendered;
export default render;
