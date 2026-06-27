import superagent from 'superagent';

const post = superagent.post;

function wrapError(err: any, res: any) {
  return err ? new Error((res || {}).text || 'error running command') : null;
}

function isKeepAliveError(err: any) {
  return err && err.message.indexOf('Request has been terminated') === 0;
}

export default function runShellCommand(command: string, callback?: any, widgetId?: string) {
  const request = post('/run/').retry(2, isKeepAliveError);
  if (widgetId) request.set('X-Widget-Id', widgetId);
  request.send(command);
  return callback
    ? request.end((err: any, res: any) => callback(wrapError(err, res), (res || {}).text))
    : request
        .catch((err: any) => {
          throw wrapError(err, err.response);
        })
        .then((res: any) => res.text);
}
