import wsModule from 'ws';

const WebSocket: any = typeof window !== 'undefined'
  ? (window as any).WebSocket
  : wsModule;

let ws: any = null;
let isOpenFlag = false;

const messageListeners: Array<(data: any) => void> = [];
const openListeners: Array<() => void> = [];

function handleWSOpen() {
  isOpenFlag = true;
  openListeners.forEach((f) => f());
}

function handleWSCosed() {
  isOpenFlag = false;
}

function handleMessage(data: any) {
  messageListeners.forEach((f) => f(data));
}

function handleError(err: any) {
  console.error(err);
}

function open(url: string) {
  ws = new WebSocket(url, ['ws'], {origin: 'dynamicd'});

  if (ws.on) {
    ws.on('open', handleWSOpen);
    ws.on('close', handleWSCosed);
    ws.on('message', handleMessage);
    ws.on('error', handleError);
  } else {
    ws.onopen = handleWSOpen;
    ws.onclose = handleWSCosed;
    ws.onmessage = (e: any) => handleMessage(e.data);
    ws.onerror = handleError;
  }
}

function close() {
  ws.close();
  ws = null;
}

function isOpen() {
  return ws && isOpenFlag;
}

function onMessage(listener: (data: any) => void) {
  messageListeners.push(listener);
}

function onOpen(listener: () => void) {
  openListeners.push(listener);
}

function send(data: any) {
  ws.send(data);
}

export default { open, close, isOpen, onMessage, onOpen, send };
