// Simple recursive-setTimeout loop. Each tick calls `callback(done)` with a
// `done(nextDurationMs)` continuation. Passing `done(false)` stops the loop
// without clearing `started` so `forceTick()` still works afterwards.
export default function Timer() {
  let callback = (done) => done();
  let started = false;
  let timer;

  function scheduleTick(tick, duration) {
    if (duration !== false) return setTimeout(tick, duration);
  }

  function loop() {
    clearTimeout(timer);
    if (started) {
      callback((nextTickDuration) => {
        timer = scheduleTick(loop, nextTickDuration);
      });
    }
  }

  const api = {
    start() {
      if (!started) {
        started = true;
        loop();
      }
      return api;
    },
    stop() {
      if (started) {
        started = false;
        clearTimeout(timer);
      }
      return api;
    },
    map(cb) {
      callback = cb;
      return api;
    },
    forceTick() {
      callback(() => {});
      return api;
    },
  };
  return api;
}
