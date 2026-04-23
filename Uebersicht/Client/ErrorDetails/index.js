import { h } from 'preact';
import ErrorLine from './ErrorLine.js';

const style = {
  background: '#fff',
  padding: '20px 30px',
  fontSize: '12px',
  fontFamily: 'monospace',
};
const message = {
  fontSize: '12px',
  color: 'red',
  marginBottom: 20,
  whiteSpace: 'pre',
};
const code = { lineHeight: '1.5', whiteSpace: 'pre', fontFamily: 'monospace' };
const table = { borderCollapse: 'collapse' };

export default function ErrorDetails(props) {
  const { lines, line, column } = props;
  return h('div', { style },
    h('h1', { style: message, key: 'h1' }, props.message),
    h('p', { key: 'p' }, 'in ' + props.path + ':'),
    h('table', { style: table, key: 'table' },
      h('tbody', { style: code },
        (lines || []).map((l, i) => {
          const args = { key: i, hasError: l.lineNum === line, column };
          return ErrorLine(Object.assign({}, l, args));
        }),
      ),
    ),
  );
}
