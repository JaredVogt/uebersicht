'use strict';

const runShellCommand = require('./runShellCommand');

module.exports = function runCommand(widget, callback, dispatch) {
  const {command, refreshFrequency, id} = widget;

  if (typeof command === 'function') {
    command.apply(widget, [callback]);
  } else if (typeof command === 'string') {
    runShellCommand(command, callback, id).timeout(refreshFrequency);
  } else {
    callback();
  }
};
