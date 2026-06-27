export default function disallowIFraming(req: any, res: any, next: () => void) {
  res.setHeader('X-Frame-Options', 'sameorigin');
  next();
}
