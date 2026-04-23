import * as ws from './SharedSocket.js';

const queuedMessages = [];

function drainQueuedMessages() {
  queuedMessages.forEach((m) => ws.send(m));
  queuedMessages.length = 0;
}

ws.onOpen(drainQueuedMessages);

export default function dispatch(message) {
  const serialized = JSON.stringify(message);
  if (ws.isOpen()) {
    ws.send(serialized);
  } else {
    queuedMessages.push(serialized);
  }
}
