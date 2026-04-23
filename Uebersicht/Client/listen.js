import * as ws from './SharedSocket.js';

const listeners = [];

// `BATCH` is a transport-level envelope the server uses to coalesce a burst
// of actions into one WS frame. Unwrap it here so the rest of the client
// just sees N individual actions as if they'd arrived separately.
function fanOut(message) {
  if (message && message.type === 'BATCH' && Array.isArray(message.payload)) {
    for (const inner of message.payload) fanOut(inner);
    return;
  }
  if (message) listeners.forEach((f) => f(message));
}

ws.onMessage((data) => {
  let message;
  try { message = JSON.parse(data); } catch { /* ignore */ }
  fanOut(message);
});

export default function listen(callback) {
  listeners.push(callback);
}
