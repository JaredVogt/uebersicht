import http from 'http';

export default function httpGet(url: string, callback: (res: any, body: string) => void) {
  let buffer = '';

  http.get(url, function(res) {
    res.setEncoding('utf8');
    res.on('data', (chunk) => buffer += chunk );
    res.on('end', () => callback(res, buffer) );
  });
}
