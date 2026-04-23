// Lightweight performance overlay for Uebersicht. Fetches /perf from the
// local server (no shell spawn, no websocket roundtrip) and renders a small
// monospace panel with per-widget breakdown + hide/show controls.

const PERF_WIDGET_ID = 'Perf';

export const refreshFrequency = 2000;

export const command = () =>
  fetch('/perf', { cache: 'no-store' }).then((r) => r.text());

export const className = `
  bottom: 12px;
  right: 12px;
  padding: 10px 14px;
  background: rgba(20, 20, 22, 0.85);
  color: #d4d4d4;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 11px;
  line-height: 1.45;
  border-radius: 8px;
  min-width: 320px;
  max-width: 420px;
  user-select: none;
  border: 1px solid rgba(255, 255, 255, 0.08);
  z-index: 9999;

  h2 {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    margin: 8px 0 3px;
    color: #888;
    font-weight: 500;
  }
  h2:first-child { margin-top: 0; }

  table { border-collapse: collapse; width: 100%; }
  td, th { padding: 1px 0; vertical-align: top; text-align: left; font-weight: normal; }
  td.k, th.k { color: #999; padding-right: 10px; }
  td.v, th.v { color: #7ee787; text-align: right; font-variant-numeric: tabular-nums; padding-left: 8px; }

  table.widgets td { font-size: 10px; padding: 2px 4px 2px 0; }
  table.widgets td.id { color: #79c0ff; max-width: 180px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  table.widgets td.num { color: #d4d4d4; text-align: right; font-variant-numeric: tabular-nums; }
  table.widgets tr.hidden td.id { color: #555; text-decoration: line-through; }
  table.widgets tr.self td.id { color: #ffa657; }

  button {
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.12);
    color: #d4d4d4;
    font-family: inherit;
    font-size: 9px;
    padding: 1px 6px;
    border-radius: 3px;
    cursor: pointer;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
  button:hover { background: rgba(255, 255, 255, 0.15); }
  button.show { color: #7ee787; }
  button.hide { color: #ff7b72; }
`;

function postControl(id, action) {
  return fetch('/widget-control', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id, action }),
  });
}

const KV = ({ k, v }) => (
  <tr>
    <td className="k">{k}</td>
    <td className="v">{v}</td>
  </tr>
);

export const render = ({ output, error }) => {
  if (error) return <div>perf err: {String(error.message || error)}</div>;
  if (!output) return <div>loading…</div>;

  let s;
  try {
    s = JSON.parse(output);
  } catch (e) {
    return <div>parse err</div>;
  }

  return (
    <div>
      <h2>commands</h2>
      <table>
        <tbody>
          <KV k="last 1s" v={s.commands.last1s} />
          <KV k="last 10s" v={s.commands.last10s} />
          <KV k="avg dur" v={`${s.commands.avgDurationMs10s} ms`} />
          <KV k="bytes/s" v={s.commands.bytesPerSec10s} />
          <KV k="total" v={s.commands.total} />
        </tbody>
      </table>

      <h2>websocket</h2>
      <table>
        <tbody>
          <KV k="msg/s" v={s.websocket.msgPerSec10s} />
          <KV k="bytes/s" v={s.websocket.bytesPerSec10s} />
          <KV k="total" v={s.websocket.total} />
        </tbody>
      </table>

      <h2>node</h2>
      <table>
        <tbody>
          <KV k="rss" v={`${s.node.rssMB} MB`} />
          <KV k="heap" v={`${s.node.heapUsedMB}/${s.node.heapTotalMB} MB`} />
          <KV k="uptime" v={`${s.uptimeSec}s`} />
        </tbody>
      </table>

      <h2>per widget (sorted by recent activity)</h2>
      <table className="widgets">
        <thead>
          <tr>
            <th className="id">id</th>
            <th className="num">10s</th>
            <th className="num">total</th>
            <th className="num">avg</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {s.widgets.map((w) => {
            const isSelf = w.id === PERF_WIDGET_ID;
            const cls =
              (w.hidden ? 'hidden' : '') + (isSelf ? ' self' : '');
            return (
              <tr key={w.id} className={cls}>
                <td className="id" title={w.id}>{w.id}</td>
                <td className="num">{w.last10s}</td>
                <td className="num">{w.commands}</td>
                <td className="num">{w.avgMs}ms</td>
                <td>
                  {w.hidden ? (
                    <button className="show" onClick={() => postControl(w.id, 'show')}>show</button>
                  ) : (
                    <button className="hide" onClick={() => postControl(w.id, 'hide')}>hide</button>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

      {s.commands.topCommands.length > 0 && (
        <div>
          <h2>top commands</h2>
          <table className="widgets">
            <tbody>
              {s.commands.topCommands.map((c, i) => (
                <tr key={i}>
                  <td className="id" title={c.command}>{c.command}</td>
                  <td className="num">{c.count}×</td>
                  <td className="num">{c.avgMs}ms</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
};
