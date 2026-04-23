// `run(cmd)` widget helper: POSTs a shell command to the in-process server's
// `/run/` endpoint and resolves with the stdout text. Replaces the legacy
// superagent-backed version; native `fetch` is enough here.
export default function runShellCommand(command, callback, widgetId) {
  const headers = { 'Content-Type': 'text/plain;charset=utf-8' };
  if (widgetId) headers['X-Widget-Id'] = widgetId;
  const promise = fetch('/run/', { method: 'POST', headers, body: command })
    .then(async (res) => {
      const text = await res.text();
      if (!res.ok) {
        throw new Error(text || 'error running command');
      }
      return text;
    });
  if (callback) {
    promise.then(
      (text) => callback(null, text),
      (err) => callback(err, null),
    );
    return;
  }
  return promise;
}
