import test from 'tape';
import widgetify from '../../src/widgetify';
import through from 'through2';

function grabOutput(then: (output: string) => void) {
  let output = '';
  return through(
    (chunk: any, enc: any, next: any) => { output += chunk; next(); },
    (next: any) => { then(output); next(); }
  );
}

test('transforming valid widgets', (t) => {
  const transform = widgetify('path/', { id: 'foo' });
  const src = `
    var color = '#ff';
    var stuff = 1+2;
    color = color + 'f';
    ({
      foo: 14,
      style: 'color: ' + color,
      refreshFrequency: '2s'
    })
  `;

  transform.pipe( grabOutput((transformed) => {
    const module: any = {};
    new Function('module', transformed)(module);

    t.ok(
      typeof module.exports === 'object',
      'it assigns the last object expression to module.exports'
    );
    t.equal(
      module.exports.id, 'foo',
      'it adds the widget id'
    );
    t.equal(
      module.exports.refreshFrequency, 2000,
      'it parses string refresh frequencies'
    );
    t.equal(
      module.exports.css, '#foo {\n  color: #fff;\n}\n',
      'it parses and scopes styles, including interpolated variables'
    );
    t.equal(
      module.exports.style, undefined,
      'it cleans up the style property'
    );

    t.end();
  }));

  transform.write(src);
  transform.end();
});

test('transforming a widget with a syntax error', (t) => {
  const transform = widgetify('path/', { id: 'foo' });
  const src = `
    ({
      foo: 14,
      style: 'color: ' + color,
      refreshFrequency: '2s'
    })
  `;

  transform
    .on('error', (e: any) => {
      t.pass('it emits an error');
      t.ok(
        e.name === 'ReferenceError' && e.message === 'color is not defined',
        'the error looks ok'
      );
      t.end();
    })
    .pipe(grabOutput((transformed) => {
      t.ok(!transformed, 'and there is no outout');
    }));

  transform.write(src);
  transform.end();
});
