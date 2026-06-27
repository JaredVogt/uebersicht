export default function ensureSameOrgin(origin: string) {
  const fromSameOrigin = (req: any) => {
    return req.method == 'GET' ||
      (req.headers.origin && req.headers.origin === origin);
  }

  return ((req: any, res: any, next: () => void) => {
    if (fromSameOrigin(req)) return next();
    res.writeHead(403);
    res.end();
  })
}
