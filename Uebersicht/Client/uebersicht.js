// Public module that widgets `import` from via the importmap:
// `uebersicht` → `/uebersicht.js`. Exports match the legacy
// `server/src/uebersicht.js` shape (`run`, `request`, `css`, `styled`,
// `React`) so shipping widgets keep working unchanged.
//
// React is aliased to Preact's React-compat layer (Preact core + 10 KB of
// shim). For Übersicht's render style (stateless functional components
// produced by JSX → `h()` calls), behaviorally identical to React 16 and
// dramatically cheaper per-diff.
//
// `styled` used to be `@emotion/styled`. That package pulls in React +
// `@emotion/react` + `@babel/runtime` — a dependency tree we don't need.
// The ~15-line shim below covers the common widget use cases
// (`styled.div(css` … `)` and `styled('h1', css` … `)`) on top of the
// framework-agnostic `@emotion/css`.

import { h, Fragment, render as preactRender, createContext } from 'preact';
import {
  useState, useEffect, useRef, useMemo, useCallback, useContext, useReducer,
} from 'preact/hooks';
import { css, cx, keyframes, injectGlobal } from '@emotion/css';
import run from './runShellCommand.js';

// Minimal React 16 shape so `import { React } from 'uebersicht'; React.createElement(...)`
// still works. Widgets that JSX-transform to `html(...)` calls don't even
// need this — `html` is a global alias for `h`.
const React = {
  createElement: h,
  Fragment,
  createContext,
  useState,
  useEffect,
  useRef,
  useMemo,
  useCallback,
  useContext,
  useReducer,
};

// `styled.<tag>` and `styled(<tag>)` factories. Returns a Preact component
// whose `className` is the emotion-hashed class plus any user-supplied
// className. Covers the common `const Box = styled.div` and
// `const Heading = styled.h1(propsFn)` shapes.
function styled(tag) {
  return (...args) => {
    const className = css(...args);
    return function StyledComponent(props = {}) {
      const merged = [className, props.className].filter(Boolean).join(' ');
      return h(tag, { ...props, className: merged });
    };
  };
}
const elements = [
  'a', 'abbr', 'article', 'aside', 'b', 'blockquote', 'br', 'button',
  'canvas', 'cite', 'code', 'dd', 'details', 'div', 'dl', 'dt', 'em',
  'fieldset', 'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3',
  'h4', 'h5', 'h6', 'header', 'hr', 'i', 'img', 'input', 'label', 'li',
  'main', 'nav', 'ol', 'option', 'p', 'pre', 'section', 'select', 'small',
  'span', 'strong', 'summary', 'table', 'tbody', 'td', 'textarea', 'tfoot',
  'th', 'thead', 'tr', 'ul', 'video',
];
for (const tag of elements) styled[tag] = styled(tag);

// Minimal `request`: most widgets that use it only do `request.get(url)`
// or `request.post(url).send(body)`. Fetch handles both without pulling in
// superagent.
function request(url, options = {}) {
  return fetch(url, options).then(async (res) => ({
    ok: res.ok,
    status: res.status,
    text: await res.text(),
    body: null,
  }));
}
request.get = (url) => request(url, { method: 'GET' });
request.post = (url) => ({
  send: (body) => request(url, { method: 'POST', body }),
});

export { run, request, css, cx, keyframes, injectGlobal, styled, React };
