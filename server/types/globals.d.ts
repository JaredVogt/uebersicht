// `html` is the React.createElement alias injected as a global by
// VirtualDomWidget (`window.html = html`) and used by widgets and the
// ErrorDetails view without importing it.
declare const html: (...args: any[]) => any;

interface Window {
  html: (...args: any[]) => any;
}
