import test from 'tape';

import render from '../../src/render';
const domEl = document.createElement('div');
document.body.appendChild(domEl); // needed to use selectors

function buildWidget(id) {
  return {
    id: id,
    implementation: {id: id, refreshFrequency: false},
    mtime: new Date(),
  };
}

const state = {
  widgets: {
    foo: buildWidget('foo'),
    bar: buildWidget('bar'),
  },
  settings: {},
  screens: ['123'],
};

const screen = {id: '123'};

test('rendering a clean slate', (t) => {
  render(state, screen, domEl);
  t.equal(domEl.childNodes.length, 2, 'it renders 2 widgets');
  t.ok(!!domEl.querySelector('#foo'), 'it renders widget foo');
  t.ok(!!domEl.querySelector('#bar'), 'it renders widget bar');
  t.end();
});

test('rendering new widgets', (t) => {
  state.widgets.baz = buildWidget('baz');

  render(state, screen, domEl);
  t.equal(domEl.childNodes.length, 3, 'it renders 3 widgets');
  t.ok(!!domEl.querySelector('#foo'), 'it renders widget foo');
  t.ok(!!domEl.querySelector('#bar'), 'it renders widget bar');
  t.ok(!!domEl.querySelector('#baz'), 'it renders widget baz');
  t.end();
});

test('destroying removed widgets', (t) => {
  delete state.widgets.bar;

  render(state, screen, domEl);
  t.equal(domEl.childNodes.length, 2, 'it leaves 2');
  t.ok(!!domEl.querySelector('#foo'), 'it does not remove widget foo');
  t.ok(!!domEl.querySelector('#baz'), 'it does not remove widget baz');
  t.end();
});

test('rendering widgets that are visible on all screens', (t) => {
  state.settings.baz = {
    showOnAllScreens: true,
  };

  render(state, screen, domEl);
  t.equal(domEl.childNodes.length, 2, 'it renders them');

  const anotherScreen = {id: '678'};
  render(state, anotherScreen, domEl);
  t.equal(domEl.childNodes.length, 2, 'it renders them on any screen');

  t.end();
});

test('rendering widgets that are pinned to the main screen', (t) => {
  state.settings.baz = {
    showOnAllScreens: false,
    showOnMainScreen: true,
  };

  render(state, screen, domEl);
  t.equal(
    domEl.childNodes.length,
    2,
    'it renders them if current screen is main',
  );

  const nonMainScreen = {id: '678'};
  render(state, nonMainScreen, domEl);
  t.equal(
    domEl.childNodes.length,
    1,
    'it does not render them if current screen is mot main',
  );
  t.end();
});

test('rendering widgets that are pinned to selected screens', (t) => {
  state.settings.baz = {
    showOnAllScreens: false,
    showOnMainScreen: false,
    showOnSelectedScreens: true,
  };

  render(state, screen, domEl);
  t.equal(
    domEl.childNodes.length,
    1,
    'it does not render them if no screen is selected',
  );

  state.settings.baz.screens = ['567'];
  render(state, screen, domEl);
  t.equal(
    domEl.childNodes.length,
    1,
    'it does not render them if current screen is not in selected screens',
  );

  state.settings.baz.screens = ['567', '123'];
  render(state, screen, domEl);
  t.equal(
    domEl.childNodes.length,
    2,
    'it renders them if current screen is in selected screens',
  );

  t.end();
});

test('performance when re-rendering', (t) => {
  let prevNode = domEl.querySelector('#foo');
  let screen = {id: '123'};
  render(state, screen, domEl);
  let newNode = domEl.querySelector('#foo');

  t.ok(
    prevNode === newNode,
    'it does not re-render nodes if it does not need to',
  );

  prevNode = domEl.querySelector('#foo');

  // new mtime
  state.widgets.foo = buildWidget('foo');
  render(state, screen, domEl);
  newNode = domEl.querySelector('#foo');

  t.ok(prevNode !== newNode, 'it does re-render nodes when it has to');

  t.end();
});

test('rendering widgets that declare a screen target in source', (t) => {
  const widget = (id, screenTarget) => ({
    id,
    implementation: {id, refreshFrequency: false, screen: screenTarget},
    mtime: new Date(),
  });

  const state = {
    widgets: {
      named: widget('named', 'Studio Display'),
      regex: widget('regex', /4K/),
      main: widget('main', 'main'),
    },
    settings: {},
    screens: ['111', '222'],
    screenNames: {111: 'Built-in Display', 222: 'Studio Display 4K'},
  };

  const studio = {id: '222'};
  render(state, studio, domEl);
  t.ok(!!domEl.querySelector('#named'), 'name match renders on matching screen');
  t.ok(!!domEl.querySelector('#regex'), 'regex match renders on matching screen');
  t.notOk(
    domEl.querySelector('#main'),
    'main target does not render on a non-main screen',
  );

  const builtIn = {id: '111'};
  render(state, builtIn, domEl);
  t.notOk(domEl.querySelector('#named'), 'name match excluded on other screen');
  t.ok(!!domEl.querySelector('#main'), 'main target renders on the main screen');

  t.end();
});

test('a user override beats the declared screen target', (t) => {
  const state = {
    widgets: {
      pinned: {
        id: 'pinned',
        implementation: {
          id: 'pinned',
          refreshFrequency: false,
          screen: 'Studio Display',
        },
        mtime: new Date(),
      },
    },
    // user picked "all screens" from the menu, so userModified is set
    settings: {pinned: {showOnAllScreens: true, userModified: true}},
    screens: ['111'],
    screenNames: {111: 'Built-in Display'},
  };

  render(state, {id: '111'}, domEl);
  t.ok(
    !!domEl.querySelector('#pinned'),
    'declared target is ignored once the user has overridden it',
  );
  t.end();
});

test('rendering background widgets', (t) => {
  let state = {
    widgets: {
      foo: buildWidget('foo'),
    },
    settings: {foo: {inBackground: true, showOnAllScreens: true}},
    screens: ['123'],
  };

  render(state, screen, domEl);
  t.equal(domEl.childNodes.length, 1, 'it renders them if layer is not set');
  const undefinedLayer = {id: '123', layer: undefined};
  render(state, undefinedLayer, domEl);
  t.equal(domEl.childNodes.length, 1, 'it renders them if layer is undefined');

  const foregroundLayer = {id: '123', layer: 'foreground'};
  render(state, foregroundLayer, domEl);
  t.equal(
    domEl.childNodes.length,
    0,
    'it does not render them if layer is "foreground"',
  );

  const backgroundLayer = {id: '123', layer: 'background'};
  render(state, backgroundLayer, domEl);
  t.equal(
    domEl.childNodes.length,
    1,
    'it renders them if layer is "background"',
  );
  t.end();
});
