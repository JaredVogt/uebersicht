import runShellCommand from './runShellCommand';

export default function runCommand(widget: any, callback: any, dispatch?: any) {
  const {command, refreshFrequency, id} = widget;

  if (typeof command === 'function') {
    command.apply(widget, [callback]);
  } else if (typeof command === 'string') {
    runShellCommand(command, callback, id).timeout(refreshFrequency);
  } else {
    callback();
  }
}
