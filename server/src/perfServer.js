'use strict';

const PerfCollector = require('./PerfCollector');

module.exports = function perfServer(getStoreState) {
  return function (req, res, next) {
    if (req.method !== 'GET' || req.url !== '/perf') return next();
    const body = JSON.stringify(PerfCollector.snapshot(getStoreState));
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
      'Cache-Control': 'no-store',
    });
    res.end(body);
  };
};
