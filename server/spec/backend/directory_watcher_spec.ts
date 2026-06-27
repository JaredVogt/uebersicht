import test from 'tape';
import * as path from 'path';
import * as fs from 'fs';
import { execSync } from 'child_process';

import DirWatcher from '../../src/directory_watcher';
const fixturePath = path.resolve(__dirname, '../test_widgets');
const newWidgetPath = path.join(fixturePath, 'new-widget.coffee');

let stopWatching: () => void;
let callback: (event: any) => void;

const throwError = (err: any) => {
  if (err) throw err;
};

test('files that are already present in the widget dir', (t) => {
  t.timeoutAfter(300);
  const expectedWidgets = [
    path.join(fixturePath, 'widget-1.coffee'),
    path.join(fixturePath, 'widget-2.js'),
    path.join(fixturePath, 'some-dir.widget', 'index-1.coffee'),
    path.join(fixturePath, 'broken-widget.coffee'),
    path.join(fixturePath, 'invalid-widget.coffee'),
  ];

  callback = (event) => {
    if (event.type !== 'added') {
      return;
    }
    const idx = expectedWidgets.indexOf(event.filePath);
    if (idx > -1) {
      expectedWidgets.splice(idx, 1);
    }

    if (expectedWidgets.length === 0) {
      callback = () => {};
      t.pass('it emits an event for all widgets already in the folder');
      t.end();
    }
  };

  stopWatching = DirWatcher(fixturePath, (event: any) => callback(event));
});

test('adding files', (t) => {
  t.timeoutAfter(300);
  callback = (event) => {
    if (event.type === 'added' && event.filePath === newWidgetPath) {
      callback = () => {};
      t.pass('it emits an event for new files');
      t.equal(event.rootPath, fixturePath, 'the event includes the root path');
      t.end();
    }
  };
  fs.writeFile(newWidgetPath, "command: ''", throwError);
});

test('removing files', (t) => {
  t.timeoutAfter(300);
  callback = (event) => {
    if (event.type === 'removed' && event.filePath === newWidgetPath) {
      callback = () => {};
      t.pass('it emits a removed event when a widget file is removed');
      t.equal(event.rootPath, fixturePath, 'the event includes the root path');
      t.end();
    }
  };
  fs.unlink(newWidgetPath, throwError);
});

test('adding folders', (t) => {
  t.timeoutAfter(300);
  const aWidgetFolder = path.resolve(__dirname, '../tmp2');
  if (fs.existsSync(aWidgetFolder)) {
    execSync('rm -rf ' + aWidgetFolder);
  }

  fs.mkdirSync(aWidgetFolder);
  fs.writeFileSync(path.join(aWidgetFolder, 'widget.js'), "command: 'yay'");

  const expectedPath = path.join(fixturePath, 'another', 'widget.js');
  callback = (event) => {
    if (event.type === 'added' && event.filePath === expectedPath) {
      callback = () => {};
      t.pass('it emits an event when a subfolder containing a widget is added');
      t.end();
    }
  };
  fs.rename(aWidgetFolder, path.join(fixturePath, 'another'), throwError);
});

test('removing folders', (t) => {
  t.timeoutAfter(300);
  const expectedPath = path.join(fixturePath, 'another', 'widget.js');
  callback = (event) => {
    if (event.type === 'removed' && event.filePath === expectedPath) {
      callback = () => {};
      t.pass(
        'it emits a removed event when a subfolder containing a ' +
          'widget is removed',
      );
      t.end();
    }
  };

  const newPath = path.resolve(__dirname, '../tmp3');
  fs.renameSync(path.join(fixturePath, 'another'), newPath);
  execSync('rm -rf ' + newPath);
});

test('stopping', (t) => {
  stopWatching();
  t.pass('it can be stopped');
  t.end();
});
