import bundleWidget from './bundleWidget';
import * as fs from 'fs';

export default function WidgetBundler() {
  const api: any = {};
  const bundles: any = {};

  api.push = function push(action: any, callback: any) {
    if (action && action.type) {
      action.type === 'added'
        ? addWidget(action.id, action.filePath, callback)
        : removeWidget(action.id, action.filePath, callback)
        ;
    }
  };

  api.close = function close() {
    for (const id in bundles) {
      bundles[id].close();
      delete bundles[id];
    }
  };

  api.get = function get(id: string) {
    return bundles[id].widget.body;
  };

  function addWidget(id: string, filePath: string, emit: any) {
    if (!bundles[id]) {
      bundles[id] = WidgetBundle(id, filePath, (widget: any) => {
        emit({type: 'added', widget: widget});
      });
    }
  }

  function removeWidget(id: string, filePath: string, emit: any) {
    if (bundles[id]) {
      bundles[id].close();
      delete bundles[id];
      emit({type: 'removed', id: id});
    }
  }

  function WidgetBundle(id: string, filePath: string, callback: any) {
    const bundle = bundleWidget(id, filePath);
    const buildWidget = (paths: any[] = []) => {
      const widget: any = {
        id: id,
        filePath: filePath,
      };

      fs.access(filePath, (fs as any).R_OK, (couldNotRead: any) => {
        if (couldNotRead) return;
        bundle.bundle((err: any, srcBuffer: any) => {
          if (err) {
            widget.error = errorJSON(filePath, err);
          } else {
            widget.body = srcBuffer.toString();
          }

          widget.mtime = fs.statSync(paths[0] || filePath).mtime;
          bundle.widget = widget;
          callback(widget);
        });
      });
    };

    bundle.on('update', buildWidget);
    buildWidget();
    return bundle;
  }

  function errorJSON(filePath: string, error: any) {
    if (!error._babel) {
      return JSON.stringify({
        line: error.line,
        column: error.column,
        path: filePath,
        lines: error.annotated,
        message: error.message,
      });
    }
    return JSON.stringify({
      line: error.loc.line,
      column: error.loc.column,
      lines: parseCodeFrame(error.codeFrame),
      path: filePath,
      message: error.message,
    });
  }

  function parseCodeFrame(codeFrame: string) {
    return codeFrame
      .split('\n')
      .map(l => {
        const [num, line] = l.split('|', 2);
        const lineNum = parseInt(num.replace(/^>/, ''), 10);
        return isNaN(lineNum) ? undefined : {lineNum: lineNum, line: line};
      })
      .filter(i => i);
  }

  return api;
}
