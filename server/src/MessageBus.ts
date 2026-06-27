import WebSocket from 'ws';
import PerfCollector from './PerfCollector';

function byteLengthOf(data: any) {
  if (Buffer.isBuffer(data)) return data.length;
  if (typeof data === 'string') return Buffer.byteLength(data);
  return 0;
}

export default function MessageBus(options: any) {
  const wss = new WebSocket.Server(options);

  function broadcast(data: any) {
    const bytes = byteLengthOf(data);
    let recipients = 0;
    wss.clients.forEach((client: any) => {
      if (client.readyState === WebSocket.OPEN) {
        client.send(data);
        recipients += 1;
      }
    });
    if (recipients > 0) {
      PerfCollector.recordWsMessage({ bytes: bytes * recipients });
    }
  }

  wss.on('connection', function connection(ws: any) {
    ws.on('message', broadcast);
  });

  wss.on('error', function handleError(err: any) {
    console.error(err);
  });

  return wss;
}
