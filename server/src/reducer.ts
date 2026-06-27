const defaultSettings = {
  showOnAllScreens: true,
  showOnMainScreen: false,
  showOnSelectedScreens: false,
  hidden: false,
  screens: [],
  userModified: false,
};

const handlers: any = {
  WIDGET_ADDED: (state: any, action: any) => {
    const widget = action.payload;
    const newWidgets = Object.assign({}, state.widgets, {
      [widget.id]: widget,
    });

    const settings = state.settings || {};
    const newSettings = settings[widget.id]
      ? state.settings
      : Object.assign({}, settings, {[widget.id]: defaultSettings});

    return Object.assign({}, state, {
      widgets: newWidgets,
      settings: newSettings,
    });
  },

  WIDGET_LOADED: (state: any, action: any) => {
    if (!state.widgets[action.id]) {
      return state;
    }
    const widget = Object.assign({}, state.widgets[action.id], {
      implementation: action.payload,
    });
    const newWidgets = Object.assign({}, state.widgets, {[widget.id]: widget});
    return Object.assign({}, state, {widgets: newWidgets});
  },

  WIDGET_REMOVED: (state: any, action: any) => {
    const id = action.payload;

    if (!state.widgets[id]) {
      return state;
    }

    const newWidgets = Object.assign({}, state.widgets);
    delete newWidgets[id];

    return Object.assign({}, state, {widgets: newWidgets});
  },

  WIDGET_SETTINGS_CHANGED: (state: any, action: any) => {
    const newSettings = Object.assign({}, state.settings, {
      [action.payload.id]: action.payload.settings,
    });

    return Object.assign({}, state, {settings: newSettings});
  },

  WIDGET_SET_TO_ALL_SCREENS: (state: any, action: any) => {
    return updateSettings(state, action.payload, {
      showOnAllScreens: true,
      showOnSelectedScreens: false,
      showOnMainScreen: false,
      hidden: false,
      screens: [],
      userModified: true,
    });
  },

  WIDGET_SET_TO_SELECTED_SCREENS: (state: any, action: any) => {
    return updateSettings(state, action.payload, {
      showOnSelectedScreens: true,
      showOnAllScreens: false,
      showOnMainScreen: false,
      hidden: false,
      userModified: true,
    });
  },

  WIDGET_SET_TO_MAIN_SCREEN: (state: any, action: any) => {
    return updateSettings(state, action.payload, {
      showOnSelectedScreens: false,
      showOnAllScreens: false,
      showOnMainScreen: true,
      hidden: false,
      screens: [],
      userModified: true,
    });
  },

  WIDGET_SET_TO_HIDE: (state: any, action: any) => {
    return updateSettings(state, action.payload, {
      hidden: true,
    });
  },

  WIDGET_SET_TO_SHOW: (state: any, action: any) => {
    return updateSettings(state, action.payload, {
      hidden: false,
    });
  },

  WIDGET_SET_TO_BACKGROUND: (state: any, action: any) => {
    return updateSettings(state, action.payload, {
      inBackground: true,
    });
  },

  WIDGET_SET_TO_FOREGROUND: (state: any, action: any) => {
    return updateSettings(state, action.payload, {
      inBackground: false,
    });
  },

  SCREEN_SELECTED_FOR_WIDGET: (state: any, action: any) => {
    const settings = state.settings[action.payload.id];
    const newScreens = (settings.screens || []).slice();

    if (newScreens.indexOf(action.payload.screenId) === -1) {
      newScreens.push(action.payload.screenId);
    }

    return updateSettings(state, action.payload.id, {
      screens: newScreens,
      userModified: true,
    });
  },

  SCREEN_DESELECTED_FOR_WIDGET: (state: any, action: any) => {
    const newScreens = (state.settings[action.payload.id].screens || []).filter(
      (s: any) => s !== action.payload.screenId,
    );

    return updateSettings(state, action.payload.id, {
      screens: newScreens,
      userModified: true,
    });
  },

  SCREENS_DID_CHANGE: (state: any, action: any) => {
    return Object.assign({}, state, {
      screens: action.payload.ids,
      screenNames: action.payload.names,
    });
  },
};

function updateSettings(state: any, widgetId: any, patch: any) {
  const widgetSettings = state.settings[widgetId];
  const newSettings = Object.assign({}, state.settings, {
    [widgetId]: Object.assign({}, widgetSettings, patch),
  });

  return Object.assign({}, state, {settings: newSettings});
}

export default function reduce(state: any, action: any) {
  let newState;
  const handler = handlers[action.type];
  if (handler) {
    newState = handler(state, action);
  } else {
    newState = state;
  }
  return newState;
}
