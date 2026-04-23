// Tiny createStore. Replaces the `redux` dep — we only use `createStore`,
// `subscribe`, `dispatch`, `getState` for the widget-rendering fan-out, and
// this is ~20 lines of drop-in-compatible code.
export default function createStore(reducer, initialState) {
  let state = initialState;
  const subscribers = [];

  function getState() { return state; }

  function dispatch(action) {
    state = reducer(state, action);
    subscribers.forEach((cb) => cb());
    return action;
  }

  function subscribe(cb) {
    subscribers.push(cb);
    return () => {
      const idx = subscribers.indexOf(cb);
      if (idx > -1) subscribers.splice(idx, 1);
    };
  }

  return { getState, dispatch, subscribe };
}
