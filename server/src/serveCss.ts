import * as fs from 'fs';
import * as path from 'path';
import * as urls from 'url';

export default (widgetsDir: string) => (req: any, res: any, next: () => void) => {
  const url = urls.parse(req.url);
  if (url.pathname !== '/userMain.css') return next();

  (fs as any).ReadStream(path.join(widgetsDir, 'main.css'))
    .on('error', (err: any) => {
      if (err.code !== 'ENOENT') throw err;
      res.end('');
    })
    .pipe(res);
};
