const post = require('superagent').post;

function wrapError(err, res) {
  return err ? new Error((res || {}).text || 'error running command') : null;
}

function isKeepAliveError(err) {
  return err && err.message.indexOf('Request has been terminated') === 0;
}

module.exports = function runShellCommand(command, callback, widgetId) {
  const request = post('/run/').retry(2, isKeepAliveError);
  if (widgetId) request.set('X-Widget-Id', widgetId);
  request.send(command);
  return callback
    ? request.end((err, res) => callback(wrapError(err, res), (res || {}).text))
    : request
        .catch((err) => {
          throw wrapError(err, err.response);
        })
        .then((res) => res.text);
};
