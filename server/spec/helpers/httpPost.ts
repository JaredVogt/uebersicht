import http from 'http';
import URL from 'url';

export default function httpPost(url: string, postData: string, callback: (res: any, body: string) => void) {
  const options: any = URL.parse(url);
  options.method = 'POST';
  options.headers = { 'Content-Length': postData.length };

  const req = http.request(options, (res) => {
    let buffer = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => buffer += chunk);
    res.on('end', () => callback(res, buffer));
  });

  req.write(postData);
  req.end();
}
