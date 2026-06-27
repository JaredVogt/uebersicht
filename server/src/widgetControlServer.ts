// POST /widget-control with JSON body { id: string, action: 'hide'|'show' }
// Triggers the corresponding redux action both locally and on the wire so all
// connected WebViews update immediately.

const ACTION_TYPES: { [key: string]: string } = {
  hide: 'WIDGET_SET_TO_HIDE',
  show: 'WIDGET_SET_TO_SHOW',
};

function readBody(req: any): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: any[] = [];
    let total = 0;
    req.on('data', (c: any) => {
      total += c.length;
      if (total > 4096) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

export default function widgetControlServer(dispatchBoth: any) {
  return function (req: any, res: any, next: any) {
    if (req.method !== 'POST' || req.url !== '/widget-control') return next();

    readBody(req)
      .then((raw) => {
        let payload;
        try {
          payload = JSON.parse(raw);
        } catch (e) {
          res.writeHead(400);
          res.end('invalid json');
          return;
        }
        const { id, action } = payload || {};
        const type = ACTION_TYPES[action];
        if (!id || !type) {
          res.writeHead(400);
          res.end('missing id or unknown action');
          return;
        }
        dispatchBoth({ type, payload: id });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      })
      .catch((err) => {
        res.writeHead(400);
        res.end(String(err.message || err));
      });
  };
}
