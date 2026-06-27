import ws from './SharedSocket';

const listeners: Array<(message: any) => void> = [];

ws.onMessage(function handleMessage(data: any) {
  let message;
  try { message = JSON.parse(data); } catch (e) { null; }

  if (message) {
    listeners.forEach((f) => f(message));
  }
});

export default function listen(callback: (message: any) => void) {
  listeners.push(callback);
}
