import test from 'tape';
import WebSocket from 'ws';

const server = new WebSocket.Server({ port: 8889 });
import sharedSocket from '../../src/SharedSocket';
import listen from '../../src/listen';

test('listen', (t) => {
  sharedSocket.open('ws://localhost:8889');

  listen((message: any) => {
    t.looseEqual(
      message,
      { type: 'YASS', payload: 'yay' },
      'it calls listeners with deserialized messages'
    );
    server.close(() => t.end());
  });

  server.on('connection', (ws) => {
    ws.send(JSON.stringify({
      type: 'YASS',
      payload: 'yay',
    }));
  });
});
