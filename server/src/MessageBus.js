'use strict';

const WebSocket = require('ws');
const PerfCollector = require('./PerfCollector');

function byteLengthOf(data) {
  if (Buffer.isBuffer(data)) return data.length;
  if (typeof data === 'string') return Buffer.byteLength(data);
  return 0;
}

module.exports = function MessageBus(options) {
  const wss = new WebSocket.Server(options);

  function broadcast(data) {
    const bytes = byteLengthOf(data);
    let recipients = 0;
    wss.clients.forEach((client) => {
      if (client.readyState === WebSocket.OPEN) {
        client.send(data);
        recipients += 1;
      }
    });
    if (recipients > 0) {
      PerfCollector.recordWsMessage({ bytes: bytes * recipients });
    }
  }

  wss.on('connection', function connection(ws) {
    ws.on('message', broadcast);
  });

  wss.on('error', function handleError(err) {
    console.error(err);
  });

  return wss;
};
