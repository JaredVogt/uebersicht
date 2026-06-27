import test from 'tape';
import reduce from '../../src/reducer';


test('WIDGET_ADDED', (t) => {
  let action: any = {
    type: 'WIDGET_ADDED',
    payload: { id: 'foo', error: 'oh no', filePath: '/foo/' },
  };
  let newState = reduce({ widgets: {} }, action);

  t.looseEqual(
    newState.widgets,
    { foo: { id: 'foo', error: 'oh no', filePath: '/foo/' } },
    'it adds new widgets'
  );

  t.ok(
    typeof newState.settings === 'object',
    'it creates a new settings hash if none exists'
  );

  t.looseEqual(
    newState.settings.foo, {
      showOnAllScreens: true,
      showOnMainScreen: false,
      showOnSelectedScreens: false,
      hidden: false,
      screens: [],
      userModified: false,
    },
    'it initializes settings for a widget'
  );

  action = {
    type: 'WIDGET_ADDED',
    payload: { id: 'foo', body: 'yay', filePath: '/foo/' },
  };
  newState = reduce(newState, action);

  t.looseEqual(
    newState.widgets,
    { foo: { id: 'foo', body: 'yay', filePath: '/foo/' } },
    'it updates existing widgets'
  );

  t.end();
});

test('WIDGET_REMOVED', (t) => {
  const action = { type: 'WIDGET_REMOVED', payload: 'foo' };
  const state = { widgets: {} };
  let newState = reduce(state, action);
  t.equal(state, newState, 'it ignores non existing widgets');

  newState = reduce({
    widgets: { foo: {}, bar: {}},
  }, action);
  t.looseEqual(newState.widgets, {bar: {}}, 'it removes existing widgets');
  t.end();
});


test('WIDGET_SETTINGS_CHANGED', (t) => {
  const action = {
    type: 'WIDGET_SETTINGS_CHANGED',
    payload: { id: 'foo', settings: { a: 'b' } },
  };

  let newState = reduce({ settings: {} }, action);
  t.looseEqual(
    newState.settings,
    { foo: { a: 'b' } },
    'it applies new settings'
  );

  newState = reduce({ settings: { bar: {} } }, action);
  t.looseEqual(
    newState.settings,
    { foo: { a: 'b' }, bar: {}},
    'it merges with existing settings'
  );

  t.end();
});

test('WIDGET_SET_TO_HIDE / SHOW', (t) => {
  let action: any = { type: 'WIDGET_SET_TO_HIDE', payload: 'bar' };
  const state = {
    settings: {
      foo: { hidden: false, some: 'other', stuff: 1 },
      bar: { hidden: false, many: 'other', things: 42 },
    },
  };
  let newState = reduce(state, action);
  t.looseEqual(
    state.settings,
    {
      foo: { hidden: false, some: 'other', stuff: 1 },
      bar: { hidden: false, many: 'other', things: 42 },
    },
    'it hides widgets'
  );

  action = { type: 'WIDGET_SET_TO_SHOW', payload: 'bar' };
  newState = reduce(newState, action);
  t.looseEqual(
    state.settings,
    {
      foo: { hidden: false, some: 'other', stuff: 1 },
      bar: { hidden: false, many: 'other', things: 42 },
    },
    'it shows widgets'
  );

  t.notOk(
    newState.settings.bar.userModified,
    'showing/hiding does not mark screen targeting as user-modified'
  );
  t.end();
});

test('screen targeting marks settings as user-modified', (t) => {
  const state = { settings: { foo: { screens: [] } }, screens: ['1', '2'] };

  ['WIDGET_SET_TO_ALL_SCREENS', 'WIDGET_SET_TO_MAIN_SCREEN'].forEach((type) => {
    const newState = reduce(state, { type, payload: 'foo' });
    t.ok(newState.settings.foo.userModified, type + ' sets userModified');
  });

  const withScreen = reduce(state, {
    type: 'SCREEN_SELECTED_FOR_WIDGET',
    payload: { id: 'foo', screenId: '1' },
  });
  t.ok(
    withScreen.settings.foo.userModified,
    'selecting a screen sets userModified'
  );
  t.end();
});

test('SCREENS_DID_CHANGE', (t) => {
  const action = {
    type: 'SCREENS_DID_CHANGE',
    payload: { ids: ['1', '2'], names: { 1: 'Built-in', 2: 'Studio Display' } },
  };
  const newState = reduce({ screens: [], screenNames: {} }, action);

  t.looseEqual(newState.screens, ['1', '2'], 'it stores the ordered screen ids');
  t.looseEqual(
    newState.screenNames,
    { 1: 'Built-in', 2: 'Studio Display' },
    'it stores the screen names by id'
  );
  t.end();
});
