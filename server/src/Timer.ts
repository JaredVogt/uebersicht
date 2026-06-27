function scheduleTick(tick: any, duration: any) {
  if (duration !== false) {
    return setTimeout(tick, duration);
  }
}

export default function Timer() {
  const api: any = {};
  let callback: any = (done: any) => done();
  let started = false;
  let timer: any;

  function loop() {
    clearTimeout(timer);
    if (started) {
      callback((nextTickDuration: any) => {
        timer = scheduleTick(loop, nextTickDuration);
      });
    }
  }

  api.start = function start() {
    if (!started) {
      started = true;
      loop();
    }
    return api;
  };

  api.stop = function stop() {
    if (started) {
      started = false;
      clearTimeout(timer);
    }
    return api;
  };

  api.map = function map(cb: any) {
    callback = cb;
    return api;
  };

  api.forceTick = function tick() {
    callback(() => {});
    return api;
  };

  return api;
}
