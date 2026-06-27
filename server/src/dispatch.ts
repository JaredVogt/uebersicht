import ws from './SharedSocket';

const queuedMessages: string[] = [];

function drainQueuedMessages() {
  queuedMessages.forEach((m) => ws.send(m));
  queuedMessages.length = 0;
}

ws.onOpen(drainQueuedMessages);

export default function dispatch(message: any) {
  const serializedMessage = JSON.stringify(message);

  if (ws.isOpen()) {
    ws.send(serializedMessage);
  } else {
    queuedMessages.push(serializedMessage);
  }
}
