import through from 'through2';
import esprima from 'esprima';
import escodegen from 'escodegen';
import stylus from 'stylus';
import nib from 'nib';
import ms from 'ms';

function addExports(node: any) {
  const widgetObjectExp = node.expression;

  node.expression = {
    type: 'AssignmentExpression',
    operator: '=',
    left: { type: 'Identifier', name: 'module.exports' },
    right: widgetObjectExp,
  };
}

function addId(widgetObjectExp: any, widetId: any) {
  const idProperty = {
    type: 'Property',
    key: { type: 'Identifier', name: 'id' },
    value: { type: 'Literal', value: widetId },
    computed: false,
  };

  widgetObjectExp.properties.push(idProperty);
}

function flattenStyle(styleProp: any, tree: any) {
  const preface = {
    type: 'Program',
    body: tree.body.slice(0, -1),
  };

  preface.body.push({
    type: 'ExpressionStatement',
    expression: styleProp.value,
  });

  return eval(escodegen.generate(preface));
}

function parseStyle(styleProp: any, widetId: any, tree: any) {
  let styleString;

  if (styleProp.value.type === 'Literal') {
    styleString = styleProp.value.value;
  } else {
    styleString = flattenStyle(styleProp, tree);
  }

  if (typeof styleString !== 'string') {
    return;
  }

  const scopedStyle = '#' + widetId
    + '\n  '
    + styleString.replace(/\n/g, '\n  ');

  const css = stylus(scopedStyle)
    .import('nib')
    .use(nib())
    .render();

  styleProp.key.name = 'css';
  styleProp.value.type = 'Literal';
  styleProp.value.value = css;
}

function parseRefreshFrequency(prop: any) {
  if (typeof prop.value.value === 'string') {
    prop.value.value = ms(prop.value.value);
  }
}

function parseWidgetProperty(prop: any, widgetId: any, tree: any) {
  switch (prop.key.name) {
    case 'style': parseStyle(prop, widgetId, tree); break;
    case 'refreshFrequency': parseRefreshFrequency(prop); break;
  }
}

function modifyAST(tree: any, widgetId: any) {
  const widgetObjectExp = getWidgetObjectExpression(tree);

  if (widgetObjectExp) {
    widgetObjectExp.properties.map(function(prop: any) {
      parseWidgetProperty(prop, widgetId, tree);
    });
    addId(widgetObjectExp, widgetId);
    addExports(tree.body[tree.body.length - 1]);
  }

  return tree;
}

function getWidgetObjectExpression(tree: any) {
  const lastStatement = tree.body[tree.body.length - 1];

  if (lastStatement && lastStatement.type === 'ExpressionStatement' ) {
    const widgetObjectExp = lastStatement.expression;
    if (widgetObjectExp.type === 'ObjectExpression') {
      return widgetObjectExp;
    }
  }

  return undefined;
}

export default function(file: any, options: any) {
  const widgetId = options.id;
  let src = '';

  function write(this: any, buf: any, enc: any, next: any) { src += buf; next(); }
  function end(this: any, next: any) {
    let tree;
    try {
      tree = esprima.parse(src);
      if (tree) {
        this.push(escodegen.generate(modifyAST(tree, widgetId)));
      }
    } catch (e) {
      this.emit('error', e);
    }

    next();
  }

  return through(write, end);
}
