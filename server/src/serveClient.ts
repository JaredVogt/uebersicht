import * as fs from 'fs';
import * as path from 'path';
import * as stream from 'stream';

export default (publicDir: string) => {
  const indexHTML = fs.readFileSync(path.join(publicDir, 'index.html'));
  return function serveClient(req: any, res: any, next: () => void) {
    const bufferStream = new stream.PassThrough();
    bufferStream.pipe(res);
    bufferStream.end(indexHTML);
  };
};
