function addWidget(widget: any) {
  const {id, filePath, error, mtime} = widget;
  return {
    type: 'WIDGET_ADDED',
    payload: {id, filePath, error, mtime},
  };
}

export function showWidget(id: any, impl: any) {
  return {
    type: 'WIDGET_LOADED',
    id: id,
    payload: impl,
  };
}

function removeWidget(id: any) {
  return {
    type: 'WIDGET_REMOVED',
    payload: id,
  };
}

export function applyWidgetSettings(id: any, settings: any) {
  return {
    type: 'WIDGET_SETTINGS_CHANGED',
    payload: { id: id, settings: settings },
  };
}

export function get(widgetEvent: any) {
  switch (widgetEvent.type) {
    case 'added': return addWidget(widgetEvent.widget);
    case 'removed': return removeWidget(widgetEvent.id);
  };
}
