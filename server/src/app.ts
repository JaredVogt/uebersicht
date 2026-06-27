import connect from 'connect';
import * as http from 'http';
import serveStatic from 'serve-static';
import * as fs from 'fs';
import {createStore} from 'redux';

import MessageBus from './MessageBus';
import watchDir from './directory_watcher';
import WidgetBundler from './WidgetBundler';
import Settings from './Settings';
import StateServer from './StateServer';
import ensureSameHost from './ensureSameHost';
import ensureSameOrigin from './ensureSameOrigin';
import disallowIFraming from './disallowIFraming';
import CommandServer from './command_server';
import perfServer from './perfServer';
import widgetControlServer from './widgetControlServer';
import serveWidgets from './serveWidgets';
import serveClient from './serveClient';
import serveCss from './serveCss';
import sharedSocket from './SharedSocket';
import * as actions from './actions';
import reducer from './reducer';
import resolveWidget from './resolveWidget';
import dispatchToRemote from './dispatch';
import listenToRemote from './listen';

type Options = {loginShell?: boolean};

export default function dynamicd(
  port: number,
  widgetPath: string,
  settingsPath: string,
  publicPath: string,
  options: Options,
  callback?: () => void,
) {
  options = options || {};

  // global store for app state
  const store = createStore(reducer as any, {
    widgets: {},
    settings: {},
    screens: [],
    screenNames: {},
  });

  // listen to remote actions
  listenToRemote((action: any) => store.dispatch(action));

  // follow symlink if widgetDirectory is one
  if (fs.lstatSync(widgetPath).isSymbolicLink()) {
    widgetPath = fs.readlinkSync(widgetPath);
  }
  widgetPath = widgetPath.normalize();

  const bundler = WidgetBundler();
  // TODO: use a stream/generator/promise pattern instead of nested callbacks
  const stopWatchingDir = watchDir(widgetPath, (fileEvent) => {
    if (fileEvent.filePath.replace(fileEvent.rootPath, '') === '/main.css') {
      dispatchToRemote({type: 'MASTER_STYLE_CHANGED'});
      return;
    }
    bundler.push(resolveWidget(fileEvent), (widgetEvent: any) => {
      const action = actions.get(widgetEvent);
      if (action) {
        store.dispatch(action);
        dispatchToRemote(action);
      }
    });
  });

  // load and replay settings
  const settings = Settings(settingsPath);

  const persisted = settings.load() as {[id: string]: any};
  for (const id of Object.keys(persisted)) {
    const action = actions.applyWidgetSettings(id, persisted[id]);
    store.dispatch(action);
    dispatchToRemote(action);
  }

  store.subscribe(() => {
    settings.persist(store.getState().settings);
  });

  // set up the server
  const host = '127.0.0.1';
  let messageBus: any = null;
  const allowedHost = `${host}:${port}`;
  const allowedOrigin = `http://${allowedHost}`;
  const middleware = connect()
    .use(disallowIFraming)
    .use(ensureSameHost(allowedHost))
    .use(ensureSameOrigin(allowedOrigin))
    .use(CommandServer(widgetPath, options.loginShell))
    .use(perfServer(() => store.getState()))
    .use(
      widgetControlServer((action: any) => {
        store.dispatch(action);
        dispatchToRemote(action);
      }),
    )
    .use(StateServer(store))
    .use(serveWidgets(bundler, widgetPath))
    .use(serveStatic(publicPath))
    .use(serveStatic(widgetPath))
    .use(serveCss(widgetPath))
    .use(serveClient(publicPath));

  const server = http.createServer(middleware);
  server.keepAliveTimeout = 35000;
  server.listen(port, host, () => {
    try {
      messageBus = MessageBus({
        server,
        verifyClient: (info: any) =>
          info.req.headers.host === allowedHost &&
          (info.origin === allowedOrigin || info.origin === 'dynamicd'),
      });
      sharedSocket.open(`ws://${host}:${port}`);
      if (callback) callback();
    } catch (e) {
      server.emit('error', e);
    }
  });

  // api
  return {
    close(cb?: () => void) {
      stopWatchingDir();
      bundler.close();
      server.close();
      sharedSocket.close();
      messageBus.close(cb);
    },

    on(ev: string, handler: (...args: any[]) => void) {
      server.on(ev, handler);
    },
  };
}
