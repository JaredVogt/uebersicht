// Client-side Redux reducer. Mirrors the server's `WidgetCoordinator.reduce`
// but owns no persistence — client state is reset each time a WebView
// loads. The server is the authority; every action the client sees arrived
// from the server's broadcast, so we just keep the in-memory mirror in sync
// so `render.js` has something to diff against.

const defaultSettings = {
  showOnAllScreens: true,
  showOnMainScreen: false,
  showOnSelectedScreens: false,
  hidden: false,
  screens: [],
};

const handlers = {
  WIDGET_ADDED(state, action) {
    const widget = action.payload;
    const newWidgets = { ...state.widgets, [widget.id]: widget };
    const settings = state.settings || {};
    const newSettings = settings[widget.id]
      ? state.settings
      : { ...settings, [widget.id]: defaultSettings };
    return { ...state, widgets: newWidgets, settings: newSettings };
  },

  WIDGET_LOADED(state, action) {
    if (!state.widgets[action.id]) return state;
    const widget = { ...state.widgets[action.id], implementation: action.payload };
    return { ...state, widgets: { ...state.widgets, [widget.id]: widget } };
  },

  WIDGET_REMOVED(state, action) {
    const id = action.payload;
    if (!state.widgets[id]) return state;
    const { [id]: _, ...rest } = state.widgets;
    return { ...state, widgets: rest };
  },

  WIDGET_SETTINGS_CHANGED(state, action) {
    return {
      ...state,
      settings: { ...state.settings, [action.payload.id]: action.payload.settings },
    };
  },

  WIDGET_SET_TO_ALL_SCREENS(state, action) {
    return updateSettings(state, action.payload, {
      showOnAllScreens: true,
      showOnSelectedScreens: false,
      showOnMainScreen: false,
      hidden: false,
      screens: [],
    });
  },

  WIDGET_SET_TO_SELECTED_SCREENS(state, action) {
    return updateSettings(state, action.payload, {
      showOnSelectedScreens: true,
      showOnAllScreens: false,
      showOnMainScreen: false,
      hidden: false,
    });
  },

  WIDGET_SET_TO_MAIN_SCREEN(state, action) {
    return updateSettings(state, action.payload, {
      showOnSelectedScreens: false,
      showOnAllScreens: false,
      showOnMainScreen: true,
      hidden: false,
      screens: [],
    });
  },

  WIDGET_SET_TO_HIDE: (state, action) => updateSettings(state, action.payload, { hidden: true }),
  WIDGET_SET_TO_SHOW: (state, action) => updateSettings(state, action.payload, { hidden: false }),
  WIDGET_SET_TO_BACKGROUND: (state, action) => updateSettings(state, action.payload, { inBackground: true }),
  WIDGET_SET_TO_FOREGROUND: (state, action) => updateSettings(state, action.payload, { inBackground: false }),

  SCREEN_SELECTED_FOR_WIDGET(state, action) {
    const settings = state.settings[action.payload.id];
    const newScreens = (settings.screens || []).slice();
    if (newScreens.indexOf(action.payload.screenId) === -1) {
      newScreens.push(action.payload.screenId);
    }
    return updateSettings(state, action.payload.id, { screens: newScreens });
  },

  SCREEN_DESELECTED_FOR_WIDGET(state, action) {
    const newScreens = (state.settings[action.payload.id].screens || [])
      .filter((s) => s !== action.payload.screenId);
    return updateSettings(state, action.payload.id, { screens: newScreens });
  },

  SCREENS_DID_CHANGE(state, action) {
    return { ...state, screens: action.payload };
  },
};

function updateSettings(state, widgetId, patch) {
  const widgetSettings = state.settings[widgetId];
  return {
    ...state,
    settings: {
      ...state.settings,
      [widgetId]: { ...widgetSettings, ...patch },
    },
  };
}

export default function reduce(state, action) {
  const handler = handlers[action.type];
  return handler ? handler(state, action) : state;
}
