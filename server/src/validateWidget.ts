function validateHasCommand(impl: any, issues: string[], message: string) {
  if (impl.refreshFrequency === false) {
    return;
  }

  if (typeof impl.command !== 'string' && impl.command !== 'function') {
    issues.push(message);
  }
}

export default function validateWidget(impl: any) {
  const issues: string[] = [];

  if (impl) {
    validateHasCommand(impl, issues, 'no command given');
  } else {
    issues.push('empty implementation');
  }

  return issues;
}
