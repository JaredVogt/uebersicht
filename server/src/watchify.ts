import through from 'through2';
import * as path from 'path';
import * as fs from 'fs';

function watchify (b: any, opts: any) {
    if (!opts) opts = {};
    const cache = b._options.cache;
    const pkgcache = b._options.packageCache;
    const delay = typeof opts.delay === 'number' ? opts.delay : 0;
    let changingDeps: any = {};
    let pending: any = false;
    let updating = false;
    const mtimes: any = {};

    const wopts: any = {persistent: true};
    if (opts.ignoreWatch) {
        wopts.ignored = opts.ignoreWatch !== true
            ? opts.ignoreWatch
            : '**/node_modules/**';
    }
    if (opts.poll || typeof opts.poll === 'number') {
        wopts.usePolling = true;
        wopts.interval = opts.poll !== true
            ? opts.poll
            : undefined;
    }

    if (cache) {
        b.on('reset', collect);
        collect();
    }

    function collect () {
        b.pipeline.get('deps').push(through.obj(function(this: any, row: any, enc: any, next: any) {
            const file = row.expose ? b._expose[row.id] : row.file;
            cache[file] = {
                source: row.source,
                deps: Object.assign({}, row.deps)
            };
            this.push(row);
            next();
        }));
    }

    b.on('file', function (file: any) {
        watchFile(file);
    });

    b.on('package', function (pkg: any) {
        const file = path.join(pkg.__dirname, 'package.json');
        if (fs.existsSync(file)) {
          watchFile(file);
        }
        if (pkgcache) pkgcache[file] = pkg;
    });

    b.on('reset', reset);
    reset();

    function reset () {
        let time: any = null;
        let bytes = 0;
        b.pipeline.get('record').on('end', function () {
            time = Date.now();
        });

        b.pipeline.get('wrap').push(through(write, end));
        function write (this: any, buf: any, enc: any, next: any) {
            bytes += buf.length;
            this.push(buf);
            next();
        }
        function end (this: any) {
            const delta = Date.now() - time;
            b.emit('time', delta);
            b.emit('bytes', bytes);
            b.emit('log', bytes + ' bytes written ('
                + (delta / 1000).toFixed(2) + ' seconds)'
            );
            this.push(null);
        }
    }

    const fwatchers: any = {};
    const fwatcherFiles: any = {};
    const ignoredFiles: any = {};

    b.on('transform', function (tr: any, mfile: any) {
        tr.on('file', function (dep: any) {
            watchFile(mfile, dep);
        });
    });
    b.on('bundle', function (bundle: any) {
        updating = true;
        bundle.on('error', onend);
        bundle.on('end', onend);
        function onend () { updating = false }
    });

    function watchFile (file: any, dep?: any) {
        dep = dep || file;
        if (!fwatchers[file]) fwatchers[file] = [];
        if (!fwatcherFiles[file]) fwatcherFiles[file] = [];
        if (fwatcherFiles[file].indexOf(dep) >= 0) return;

        const w = b._watcher(dep, wopts);
        w.setMaxListeners(0);
        w.on('error', b.emit.bind(b, 'error'));
        w.on('change', function () {
            invalidate(file);
        });
        fwatchers[file].push(w);
        fwatcherFiles[file].push(dep);
    }

    function getMTime(filePath: any) {
        let mtime: any;

        try {
            fs.statSync(filePath).mtime.getTime();
        } catch (e: any) {
            if (e.code === 'ENOENT') {
                mtime = new Date().getTime();
            } else {
                throw(e);
            }
        }

        return mtime;
    }

    function invalidate (id: any) {
        const mtime = getMTime(id);
        if ((mtimes[id] || 0) >= mtime) return;
        mtimes[id] = mtime;

        if (cache) delete cache[id];
        if (pkgcache) delete pkgcache[id];
        changingDeps[id] = true;

        if (!updating && fwatchers[id]) {
            fwatchers[id].forEach(function (w: any) {
                w.close();
            });
            delete fwatchers[id];
            delete fwatcherFiles[id];
        }

        // wait for the disk/editor to quiet down first:
        if (pending) clearTimeout(pending);
        pending = setTimeout(notify, delay);
    }

    function notify () {
        if (updating) {
            pending = setTimeout(notify, delay);
        } else {
            pending = false;
            b.emit('update', Object.keys(changingDeps));
            changingDeps = {};
        }
    }

    b.close = function () {
        Object.keys(fwatchers).forEach(function (id) {
            fwatchers[id].forEach(function (w: any) { w.close() });
        });
    };

    b._watcher = function (file: any, opts: any) {
        return fs.watch(file, opts);
    };

    return b;
}

(watchify as any).args = {
    cache: {}, packageCache: {}
};

export default watchify;
