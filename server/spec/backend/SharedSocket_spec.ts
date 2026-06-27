import test from 'tape';
import WebSocket from 'ws';

const server = new WebSocket.Server({ port: 8890 });
import sharedSocket from '../../src/SharedSocket';
const url = 'ws://localhost:8890';

test('subscribing listeners', (t) => {
  sharedSocket.onMessage((message: any) => {
    t.equal(message, 'yay');
    sharedSocket.close();
    server.close(() =>  t.end());
  });

  sharedSocket.open(url);

  server.on('connection', (ws) => {
    ws.send('yay');
  });
});
