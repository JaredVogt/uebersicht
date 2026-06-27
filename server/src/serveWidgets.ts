import * as URL from 'url';
import * as fs from 'fs';
import {SourceMapConsumer} from 'source-map';
import convert from 'convert-source-map';
import {Transform} from 'stream';
import byline from 'byline';
import * as path from 'path';

// middleware to serve widget bundles
export default (bundler: any, widgetPath: string) => (req: any, res: any, next: () => void) => {
  const url = URL.parse(req.url, true);
  const match = url.pathname!.match(/\/widgets\/(.+)$/);
  if (match) {
    const code = bundler.get(match[1]);
    if (!code) {
      res.writeHead(404);
      return res.end();
    }
    return url.search
      ? codeLines(code, widgetPath, url.query, res)
      : res.end(code);
  }

  return next();
};

function asErrorJSON(codeLocation: any, padding: number) {
  const lineNum = codeLocation.line;
  let i = 0;
  let lines: any[] = [];
  return new Transform({
    transform(line: any, _: any, next: () => void) {
      if (i >= lineNum - padding && i < lineNum + padding) {
        lines.push({lineNum: i + 1, line: line.toString()});
      }
      i++;
      next();
    },
    flush(done: any) {
      done(null, JSON.stringify({
        line: codeLocation.line,
        column: codeLocation.column,
        lines: lines,
        path: codeLocation.path,
      }));
    },
  });
}

function codeLines(source: any, widgetDir: string, options: any, res: any) {
  const padding = 5;
  const lineNum = Number(options.line) || 0;
  const column = Number(options.column) || 0;
  const converter = convert.fromSource(source);

  if (!converter) {
    res.writeHead(404);
    res.end('could not find sourcemap comment');
    return;
  }

  SourceMapConsumer.with(converter.toObject(), null, (smc: any) => {
    const origpos = smc.originalPositionFor({ line: lineNum, column: column });
    if (!origpos.source) {
      res.writeHead(404);
      res.end('no match found for line ' + lineNum + ':' + column + '\n');
      return;
    }

    origpos.path = path.relative(widgetDir, origpos.source);
    byline(fs.createReadStream(origpos.source), {keepEmptyLines: true})
      .pipe(asErrorJSON(origpos, padding))
      .pipe(res)
      .on('error', (err: any) => {
        res.writeHead(500);
        res.end(err.message);
      });
  });
}
