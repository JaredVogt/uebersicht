import PerfCollector from './PerfCollector';

export default function perfServer(getStoreState: any) {
  return function (req: any, res: any, next: () => void) {
    if (req.method !== 'GET' || req.url !== '/perf') return next();
    const body = JSON.stringify(PerfCollector.snapshot(getStoreState));
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
      'Cache-Control': 'no-store',
    });
    res.end(body);
  };
}
