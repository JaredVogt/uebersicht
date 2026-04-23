// Thin wrapper around the browser WebSocket with queued sends. Shares one
// connection per page (all widgets are in one WebView, so one socket is
// enough).
let ws = null;
let _isOpen = false;
const messageListeners = [];
const openListeners = [];

function handleWSOpen() {
  _isOpen = true;
  openListeners.forEach((f) => f());
}
function handleWSClosed() {
  _isOpen = false;
}
function handleMessage(data) {
  messageListeners.forEach((f) => f(data));
}
function handleError(err) {
  console.error(err);
}

export function open(url) {
  ws = new WebSocket(url, ['ws']);
  ws.onopen = handleWSOpen;
  ws.onclose = handleWSClosed;
  ws.onmessage = (e) => handleMessage(e.data);
  ws.onerror = handleError;
}

export function close() {
  ws.close();
  ws = null;
}

export function isOpen() {
  return ws && _isOpen;
}

export function onMessage(listener) {
  messageListeners.push(listener);
}

export function onOpen(listener) {
  openListeners.push(listener);
}

export function send(data) {
  ws.send(data);
}
