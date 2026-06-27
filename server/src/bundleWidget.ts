import browserify from 'browserify';
import watchify from './watchify';
import widgetify from './widgetify';
import coffeeify from 'coffeeify';
import babelify from 'babelify';
import jsxTransform from '@babel/preset-react';
import restSpreadTransform from '@babel/plugin-proposal-object-rest-spread';
import emotion from 'babel-plugin-emotion';
import envPreset from '@babel/preset-env';
import through from 'through2';

function wrapJSWidget() {
  let start = true;
  function write(this: any, chunk: any, enc: any, next: any) {
    if (start) {
      this.push('({');
      start = false;
    }
    next(null, chunk);
  }
  function end(this: any, next: any) {
    this.push('})');
    next();
  }

  return through(write, end);
}

export default function bundleWidget(id: string, filePath: string) {
  const isJsxWidget = filePath.match(/\.jsx$/);
  const bundle: any = browserify(filePath, {
    detectGlobals: false,
    cache: {},
    packageCache: {},
    debug: isJsxWidget,
  });

  bundle.plugin(watchify);
  bundle.require(filePath, {expose: id});
  bundle.external('dynamicd');

  if (filePath.match(/\.coffee$/)) {
    bundle.transform(coffeeify, {
      bare: true,
      header: false,
    });
    bundle.transform(widgetify, {id: id});
  } else if (isJsxWidget) {
    bundle.transform(babelify, {
      presets: [
        [envPreset, {targets: 'last 4 Safari versions', modules: 'commonjs'}],
        [jsxTransform, {pragma: 'html'}],
      ],
      plugins: [restSpreadTransform, emotion],
    });
  } else {
    bundle.transform(wrapJSWidget);
    bundle.transform(widgetify, {id: id});
  }
  return bundle;
}
