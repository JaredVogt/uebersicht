import test from 'tape';
import WebSocket from 'ws';

const server = new WebSocket.Server({ port: 8888 });
const url = 'ws://localhost:8888';
import sharedSocket from '../../src/SharedSocket';
import dispatch from '../../src/dispatch';

test('queuing up messages', (t) => {
  let expectedMessages = ['a', 'b'];

  server.on('connection', (ws) => {
    ws.on('message', (message: any) => {
      const parsed = JSON.parse(message);

      const idx = expectedMessages.indexOf(parsed);
      if (idx > -1) {
        expectedMessages.splice(idx, 1);
      }

      if (expectedMessages.length === 0) {
        t.pass('it queues up messages and sends them once the socket opens');
        server.close(() => t.end());
      }
    });
  });

  dispatch('a');
  dispatch('b');
  sharedSocket.open(url);
});
