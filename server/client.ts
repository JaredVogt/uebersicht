import * as redux from 'redux';
import $ from 'jquery';
(window as any).$ = $;

import reducer from './src/reducer';
import listenToRemote from './src/listen';
import dispatchToRemote from './src/dispatch';
import sharedSocket from './src/SharedSocket';
import render from './src/render';
import * as actions from './src/actions';
import detectWidgetHover from './src/detectWidgetHover';

let userCssLink: any = null;

// Turn a widget's `screen` export into a human label for the menu-bar UI. The
// evaluated value only exists here in the client, so we report it to the native
// app, which can't parse widget code itself.
const describeScreen = (screen: any): string | null => {
  if (screen == null) return null;
  return Array.isArray(screen) ? screen.join(', ') : String(screen);
};

window.onload = () => {
  sharedSocket.open(`ws://${window.location.host}`);
  const path = window.location.pathname.split('/');
  const screen = {id: Number(path[1]), layer: path[2]};
  const contentEl = document.getElementById('dynamicd')!;
  contentEl.innerHTML = '';
  userCssLink = Array.from(document.querySelectorAll('link')).find((el) =>
    el.href.match('userMain.css'),
  );

  detectWidgetHover(contentEl);

  getState((err: any, initialState: any) => {
    if (err != null) bail(err, 10000);
    const store = redux.createStore(reducer as any, initialState);

    const loadWidget = (id: string) =>
      fetchWidget(id).then((widgetImpl: any) => {
        store.dispatch(actions.showWidget(id, widgetImpl));
        dispatchToRemote({
          type: 'WIDGET_DECLARES_SCREEN',
          payload: {id, target: describeScreen(widgetImpl?.screen)},
        });
      });

    Object.keys(initialState.widgets).forEach((id) => loadWidget(id));

    let prevState: any = null;
    store.subscribe(() => {
      const nextState = store.getState();
      if (nextState === prevState) return;
      render(store.getState(), screen, contentEl, store.dispatch);
      prevState = nextState;
    });

    listenToRemote((action: any) => {
      if (action.type === 'WIDGET_WANTS_REFRESH') {
        (render as any).rendered[action.payload]?.instance?.forceRefresh();
      } else if (action.type === 'WIDGET_ADDED') {
        store.dispatch(action);
        if (action.payload.error) return;
        loadWidget(action.payload.id);
      } else if (action.type === 'MASTER_STYLE_CHANGED') {
        reloadUserCSS();
      } else {
        store.dispatch(action);
      }
    });
    render(initialState, screen, contentEl, store.dispatch);
  });
};

// legacy
(window as any).dynamicd = {
  makeBgSlice(canvas: any) {
    console.warn(
      'makeBgSlice has been deprecated. Please use CSS backdrop-filter ' +
        'instead: https://developer.mozilla.org/en-US/docs/Web/CSS/backdrop-filter',
    );
  },
};

window.addEventListener('contextmenu', (e) => {
  e.preventDefault();
});

const getState = (callback: (err: any, state: any) => void) => {
  $.get('/state/')
    .done((response: any) => callback(null, JSON.parse(response)))
    .fail((response: any) => callback(response, null));
};

const fetchWidget = (id: string) =>
  new Promise((resolve, reject) => {
    const scriptTag = document.createElement('script');
    scriptTag.id = id;
    scriptTag.src = '/widgets/' + id;
    scriptTag.onload = () => {
      document.head.removeChild(scriptTag);
      resolve(require(id));
    };
    scriptTag.onerror = (err) => {
      document.head.removeChild(scriptTag);
      reject(err);
    };
    document.head.appendChild(scriptTag);
  });

const reloadUserCSS = () => {
  const href = userCssLink.href.split('?')[0];
  userCssLink.href = `${href}?${new Date().getTime()}`;
};

const bail = (err: any, timeout = 0) => {
  if (err != null) console.log(err);
  setTimeout(() => {
    window.location.reload();
  }, timeout);
};
