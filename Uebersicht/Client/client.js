// Client entry. Was `server/client.coffee` in the Node era. Responsibilities:
//   1. Fetch initial state from `/state/`, build local store mirror.
//   2. Open the WebSocket so we see future actions + dispatch back.
//   3. For each known widget: dynamic-import `/widgets/<id>` and dispatch
//      `WIDGET_LOADED` with the imported module.
//   4. Render on every state change.
//
// Widgets arrive as native ESM (esbuild output), so `import('/widgets/<id>')`
// Just Works™. The old script-tag + Browserify-require dance is gone.

import createStore from './store.js';
import reducer from './reducer.js';
import * as sharedSocket from './SharedSocket.js';
import listenToRemote from './listen.js';
import render, { rendered as renderedWidgets } from './render.js';
import { showWidget } from './actions.js';
import detectWidgetHover from './detectWidgetHover.js';

let userCssLink = null;

window.addEventListener('load', () => {
  sharedSocket.open(`ws://${window.location.host}`);

  const path = window.location.pathname.split('/');
  const screen = { id: Number(path[1]), layer: path[2] };
  const contentEl = document.getElementById('uebersicht');
  contentEl.innerHTML = '';
  userCssLink = Array.from(document.querySelectorAll('link'))
    .find((el) => el.href.match('userMain.css'));

  detectWidgetHover(contentEl);

  fetch('/state/')
    .then((r) => r.json())
    .then((initialState) => {
      const store = createStore(reducer, initialState);

      // Kick off dynamic imports for every widget the server already knows
      // about. As each resolves, dispatch WIDGET_LOADED with its module.
      Object.keys(initialState.widgets).forEach((id) => {
        loadWidget(id)
          .then((impl) => store.dispatch(showWidget(id, impl)))
          .catch((err) => console.error('[ub] widget import failed', id, err.message));
      });

      let prevState = null;
      store.subscribe(() => {
        const nextState = store.getState();
        if (nextState === prevState) return;
        render(store.getState(), screen, contentEl, store.dispatch);
        prevState = nextState;
      });

      listenToRemote((action) => {
        if (action.type === 'WIDGET_WANTS_REFRESH') {
          renderedWidgets[action.payload]?.instance?.forceRefresh?.();
          return;
        }
        if (action.type === 'WIDGET_ADDED') {
          store.dispatch(action);
          if (action.payload.error) return;
          loadWidget(action.payload.id).then((impl) =>
            store.dispatch(showWidget(action.payload.id, impl))
          );
          return;
        }
        if (action.type === 'MASTER_STYLE_CHANGED') {
          reloadUserCSS();
          return;
        }
        store.dispatch(action);
      });

      render(initialState, screen, contentEl, store.dispatch);
    })
    .catch((err) => bail(err, 10000));
});

// Dynamic-import a widget module. Cache-busts with `mtime` if known so a
// widget file-watch hot-reload actually re-evaluates the module. esbuild's
// per-module identity is per-URL, so adding a `?v=<mtime>` query forces a
// fresh parse.
const widgetImports = new Map();
function loadWidget(id) {
  return fetch('/state/')
    .then((r) => r.json())
    .then((state) => {
      const widget = state.widgets[id];
      const cacheKey = `${id}@${widget?.mtime ?? ''}`;
      if (!widgetImports.has(cacheKey)) {
        widgetImports.set(
          cacheKey,
          import(/* @vite-ignore */ `/widgets/${id}?v=${widget?.mtime ?? Date.now()}`)
        );
      }
      return widgetImports.get(cacheKey);
    });
}

function reloadUserCSS() {
  if (!userCssLink) return;
  const href = userCssLink.href.split('?')[0];
  userCssLink.href = `${href}?${Date.now()}`;
}

function bail(err, timeout = 0) {
  if (err) console.log(err);
  setTimeout(() => window.location.reload(), timeout);
}

// Legacy global left in place so old widgets using it don't throw.
window.uebersicht = {
  makeBgSlice() {
    console.warn(
      'makeBgSlice has been deprecated. Use CSS backdrop-filter: ' +
      'https://developer.mozilla.org/en-US/docs/Web/CSS/backdrop-filter',
    );
  },
};

window.addEventListener('contextmenu', (e) => e.preventDefault());
