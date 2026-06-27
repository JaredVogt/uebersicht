import raf from 'raf';

export default function RenderLoop(initialState: any, render: any) {
  let currentState: any = null;
  let redrawScheduled = false;
  let inRenderingTransaction = false;

  const loop: any = {
    state: initialState,
    update: update,
  };

  function update(state: any) {
    if (inRenderingTransaction) {
      throw Error("can't update while rendering");
    }

    if (currentState === null && !redrawScheduled) {
      redrawScheduled = true;
      raf(redraw);
    }

    currentState = state;
    loop.state = currentState;
    return loop;
  }

  function redraw() {
    redrawScheduled = false;
    if (currentState === null) {
      return;
    }

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
