// rAF-coalesced render loop. `update(state)` schedules a redraw on the next
// animation frame; multiple updates within a frame collapse into one call.
export default function RenderLoop(initialState, render) {
  let currentState = null;
  let redrawScheduled = false;
  let inRenderingTransaction = false;

  const loop = {
    state: initialState,
    update,
  };

  function update(state) {
    if (inRenderingTransaction) {
      throw Error("can't update while rendering");
    }
    if (currentState === null && !redrawScheduled) {
      redrawScheduled = true;
      requestAnimationFrame(redraw);
    }
    currentState = state;
    loop.state = currentState;
    return loop;
  }

  function redraw() {
    redrawScheduled = false;
    if (currentState === null) return;
    inRenderingTransaction = true;
    try {
      render(currentState);
    } catch (err) {
      console.error(err);
    }
    inRenderingTransaction = false;
    currentState = null;
  }

  return update(initialState);
}
