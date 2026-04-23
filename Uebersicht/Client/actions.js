export function showWidget(id, impl) {
  return { type: 'WIDGET_LOADED', id, payload: impl };
}

export function applyWidgetSettings(id, settings) {
  return { type: 'WIDGET_SETTINGS_CHANGED', payload: { id, settings } };
}
