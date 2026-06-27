const WINDOW_SEC = 60;

function RingBuffer(size: number) {
  const buf = new Array(size).fill(0);
  let head = 0;
  return {
    add(v: number) {
      buf[head] = v;
      head = (head + 1) % size;
    },
    sum() {
      let s = 0;
      for (let i = 0; i < size; i++) s += buf[i];
      return s;
    },
    recent(n: number) {
      let s = 0;
      const lim = Math.min(n, size);
      for (let i = 0; i < lim; i++) {
        s += buf[(head - 1 - i + size) % size];
      }
      return s;
    },
  };
}

const startedAt = Date.now();

const buckets: {[k: string]: any} = {
  commands: RingBuffer(WINDOW_SEC),
  commandDurationMs: RingBuffer(WINDOW_SEC),
  commandBytes: RingBuffer(WINDOW_SEC),
  wsMessages: RingBuffer(WINDOW_SEC),
  wsBytes: RingBuffer(WINDOW_SEC),
};

let cur: {[k: string]: number} = {
  commands: 0,
  commandDurationMs: 0,
  commandBytes: 0,
  wsMessages: 0,
  wsBytes: 0,
};

const totals: {[k: string]: number} = {
  commands: 0,
  commandDurationMs: 0,
  commandBytes: 0,
  wsMessages: 0,
  wsBytes: 0,
};

const cmdHistogram = new Map<string, {count: number; totalMs: number}>();

const perWidget = new Map<string, any>();

function widgetEntry(id: string) {
  let e = perWidget.get(id);
  if (!e) {
    e = {
      commands: 0,
      durationMs: 0,
      bytesOut: 0,
      lastMs: 0,
      lastAt: 0,
      recent: RingBuffer(WINDOW_SEC),
      curThisSec: 0,
    };
    perWidget.set(id, e);
  }
  return e;
}

function rollBuckets() {
  for (const k of Object.keys(cur)) {
    buckets[k].add(cur[k]);
    cur[k] = 0;
  }
  for (const e of perWidget.values()) {
    e.recent.add(e.curThisSec);
    e.curThisSec = 0;
  }
}

const tick = setInterval(rollBuckets, 1000);
if (tick.unref) tick.unref();

export default {
  recordCommand({command, durationMs, bytesOut, widgetId}: any) {
    cur.commands += 1;
    cur.commandDurationMs += durationMs || 0;
    cur.commandBytes += bytesOut || 0;
    totals.commands += 1;
    totals.commandDurationMs += durationMs || 0;
    totals.commandBytes += bytesOut || 0;
    if (command) {
      const key = command.length > 80 ? command.slice(0, 77) + '...' : command;
      const prev = cmdHistogram.get(key) || {count: 0, totalMs: 0};
      prev.count += 1;
      prev.totalMs += durationMs || 0;
      cmdHistogram.set(key, prev);
    }
    if (widgetId) {
      const e = widgetEntry(widgetId);
      e.commands += 1;
      e.durationMs += durationMs || 0;
      e.bytesOut += bytesOut || 0;
      e.lastMs = durationMs || 0;
      e.lastAt = Date.now();
      e.curThisSec += 1;
    }
  },

  recordWsMessage({bytes}: any) {
    cur.wsMessages += 1;
    cur.wsBytes += bytes || 0;
    totals.wsMessages += 1;
    totals.wsBytes += bytes || 0;
  },

  snapshot(getStoreState?: any) {
    const cmdLast10 = buckets.commands.recent(10);
    const cmdDur10 = buckets.commandDurationMs.recent(10);
    const wsMsg10 = buckets.wsMessages.recent(10);
    const wsBytes10 = buckets.wsBytes.recent(10);
    const mem = process.memoryUsage();

    const top = [...cmdHistogram.entries()]
      .sort((a, b) => b[1].count - a[1].count)
      .slice(0, 5)
      .map(([cmd, v]) => ({
        command: cmd,
        count: v.count,
        avgMs: Math.round(v.totalMs / v.count),
      }));

    const settingsById = getStoreState ? getStoreState().settings || {} : {};
    const widgetsById = getStoreState ? getStoreState().widgets || {} : {};

    const allIds = new Set([...perWidget.keys(), ...Object.keys(widgetsById)]);
    const widgets = [...allIds]
      .map((id) => {
        const e = perWidget.get(id);
        const settings = settingsById[id] || {};
        const known = !!widgetsById[id];
        return {
          id,
          known,
          hidden: !!settings.hidden,
          commands: e ? e.commands : 0,
          avgMs: e && e.commands > 0 ? Math.round(e.durationMs / e.commands) : 0,
          lastMs: e ? e.lastMs : 0,
          last10s: e ? e.recent.recent(10) : 0,
          last60s: e ? e.recent.sum() : 0,
        };
      })
      .sort((a, b) => b.last10s - a.last10s || b.commands - a.commands);

    return {
      uptimeSec: Math.floor((Date.now() - startedAt) / 1000),
      commands: {
        last1s: buckets.commands.recent(1),
        last10s: cmdLast10,
        last60s: buckets.commands.sum(),
        total: totals.commands,
        avgDurationMs10s: cmdLast10 > 0 ? Math.round(cmdDur10 / cmdLast10) : 0,
        bytesPerSec10s: Math.round(buckets.commandBytes.recent(10) / 10),
        topCommands: top,
      },
      websocket: {
        msgPerSec10s: Math.round(wsMsg10 / 10),
        bytesPerSec10s: Math.round(wsBytes10 / 10),
        last60s: buckets.wsMessages.sum(),
        total: totals.wsMessages,
        totalBytes: totals.wsBytes,
      },
      node: {
        rssMB: Math.round(mem.rss / 1024 / 1024),
        heapUsedMB: Math.round(mem.heapUsed / 1024 / 1024),
        heapTotalMB: Math.round(mem.heapTotal / 1024 / 1024),
        externalMB: Math.round(mem.external / 1024 / 1024),
      },
      widgets,
    };
  },
};
