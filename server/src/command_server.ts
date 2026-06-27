// middleware to serve the results of shell commands
// Listens to POST /run/
import {spawn} from 'child_process';
import type {IncomingMessage, ServerResponse} from 'http';

import PerfCollector from './PerfCollector';

type Next = () => void;

export default function commandServer(
  workingDir: string,
  useLoginShell?: boolean,
) {
  const args = useLoginShell ? ['-l'] : [];

  // the Connect middleware
  return (req: IncomingMessage, res: ServerResponse, next: Next) => {
    if (req.method !== 'POST' || req.url !== '/run/') return next();

    const startTime = Date.now();
    let bytesOut = 0;
    let commandStr = '';
    const widgetId = (req.headers['x-widget-id'] as string) || null;
    const shell = spawn('bash', args, {cwd: workingDir});

    req.on('data', (chunk: Buffer) => {
      if (commandStr.length < 200) commandStr += chunk.toString();
      shell.stdin.write(chunk);
    });

    req.on('end', () => {
      let setStatusOnce = (status: number) => {
        res.writeHead(status);
        setStatusOnce = () => {};
      };

      shell.stderr.on('data', (d: Buffer) => {
        setStatusOnce(500);
        res.write(d);
      });

      shell.stdout.on('data', (d: Buffer) => {
        bytesOut += d.length;
        setStatusOnce(200);
        res.write(d);
      });

      shell.on('error', (err: Error) => {
        setStatusOnce(500);
        res.write(err.message);
      });

      shell.on('close', () => {
        setStatusOnce(200);
        res.end();
        PerfCollector.recordCommand({
          command: commandStr.trim(),
          durationMs: Date.now() - startTime,
          bytesOut,
          widgetId,
        });
      });

      shell.stdin.write('\n');
      shell.stdin.end();
    });
  };
}
