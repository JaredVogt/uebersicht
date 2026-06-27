// Minimal declarations for npm dependencies that ship no TypeScript types.
// They are typed as `any` so our own code type-checks without pulling in a pile
// of @types packages; tighten these up if/when it's worth it. Local .js modules
// don't need entries here — `allowJs` resolves them (as implicit `any`).
//
// Modules that ship their own types (e.g. redux, source-map) are intentionally
// omitted to avoid duplicate-declaration conflicts.

// server / middleware
declare module 'connect';
declare module 'serve-static';
declare module 'minimist';
declare module 'cors-anywhere';
declare module 'fsevents';
declare module 'ws';

// view layer
declare module 'jquery';
declare module 'react';
declare module 'react-dom';
declare module 'emotion';
declare module '@emotion/styled';
declare module 'raf';
declare module 'superagent';

// widget bundling pipeline
declare module 'browserify';
declare module 'watchify';
declare module 'coffeeify';
declare module 'babelify';
declare module 'babel-plugin-emotion';
declare module '@babel/preset-env';
declare module '@babel/preset-react';
declare module '@babel/plugin-proposal-object-rest-spread';
declare module 'convert-source-map';
declare module 'esprima';
declare module 'escodegen';
declare module 'stylus';
declare module 'nib';
declare module 'through2';
declare module 'byline';
declare module 'tosource';
declare module 'ms';

// tests
declare module 'tape';
declare module 'sinon';
