import * as paths from 'path';
import * as fs from 'fs';
import fsevents from 'fsevents';

type FileEvent = {
  type: 'added' | 'removed';
  filePath: string;
  rootPath: string;
};
type WidgetCallback = (event: FileEvent) => void;
type PathType = 'file' | 'directory';

export default function watchDirectory(
  directoryPath: string,
  callback: WidgetCallback,
) {
  const foundPaths: {[path: string]: boolean} = {};
  let closed = true;
  let stopWatching: (() => void) | null = null;

  const registerFile = (filePath: string) => {
    filePath = filePath.normalize();
    foundPaths[filePath] = true;
    callback({
      type: 'added',
      filePath: filePath.normalize(),
      rootPath: directoryPath,
    });
  };

  const unregisterFiles = (path: string) => {
    path = path.normalize();
    for (const filePath of Object.keys(foundPaths)) {
      if (filePath.indexOf(path) === 0) {
        callback({type: 'removed', filePath, rootPath: directoryPath});
      }
    }
  };

  // get type of path as either 'file' or 'directory'. The callback gets called
  // with (path, type) where path is the path passed in, for convenience
  const getPathType = (
    path: string,
    cb: (path: string, type: PathType) => void,
  ) => {
    fs.stat(path, (err, stat) => {
      if (err) return console.log(err);
      cb(path, stat.isDirectory() ? 'directory' : 'file');
    });
  };

  // recursively walks the directory tree and calls onFound for every file it
  // finds
  const findFiles = (
    path: string,
    type: PathType,
    onFound: (p: string) => void,
  ) => {
    if (type === 'file') {
      onFound(path);
    } else {
      fs.readdir(path, (err, subPaths) => {
        if (err) return console.log(err);
        for (const subPath of subPaths) {
          if (subPath === 'inactive') continue;
          const fullPath = paths.join(path, subPath);
          getPathType(fullPath, (p, t) => findFiles(p, t, onFound));
        }
      });
    }
  };

  const close = () => {
    closed = true;
    if (stopWatching) stopWatching();
  };

  const init = () => {
    if (!fs.existsSync(directoryPath)) {
      throw new Error(`could not find ${directoryPath}`);
    }

    closed = false;
    stopWatching = fsevents.watch(
      directoryPath,
      (filePath: string, flags: number, id: number) => {
        if (closed) return;
        const info = fsevents.getInfo(filePath, flags, id);
        switch (info.event) {
          case 'modified':
          case 'created':
            findFiles(filePath, info.type, registerFile);
            break;
          case 'deleted':
            unregisterFiles(filePath);
            break;
          case 'moved':
            unregisterFiles(filePath);
            findFiles(filePath, info.type, registerFile);
            break;
        }
      },
    );

    console.log('watching', directoryPath);

    findFiles(directoryPath, 'directory', registerFile);
    return close;
  };

  return init();
}
