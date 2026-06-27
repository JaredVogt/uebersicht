import * as path from 'path';
import * as fs from 'fs';

export default function Settings(settingsDirPath: string) {
  const api: any = {};
  let settings: any;
  const settingsFile = path.join(settingsDirPath, 'WidgetSettings.json');

  initSettingsFile(settingsDirPath);

  function initSettingsFile(dirPath: string) {
    if (!fs.existsSync(dirPath)) {
      fs.mkdirSync(dirPath);
    }
  }

  api.load = function load() {
    let persistedSettings = {};
    try {
      persistedSettings = require(settingsFile);
    } catch (e) { /* do nothing */ }

    return persistedSettings;
  };

  api.persist = function persist(newSettings: any) {
    if (newSettings !== settings) {
      fs.writeFile(settingsFile, JSON.stringify(newSettings), (err) => {
        if (err) {
          console.log(err);
        } else {
          settings = newSettings;
        }
      });
    }
  };

  return api;
}
