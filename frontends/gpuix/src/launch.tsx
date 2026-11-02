/** Builds the app, opens the GPUIX window hidden and hands it to the platform layer. */
import { render } from "@gpuix/react";
import { Controller } from "./app/controller";
import { runBench } from "./bench";
import { applicationFolders, loadApps } from "./domain/apps";
import { PANEL_WIDTH, SEARCH_HEIGHT } from "./domain/metrics";
import { dataDir } from "./domain/paths";
import { SqliteClipStore } from "./platform/clip-sqlite";
import { CoreFiles } from "./platform/core-files";
import { IconCache } from "./platform/icons";
import { defaultIndexPath, ensureDir } from "./platform/index-file";
import { App } from "./ui/App";
import { ServicesContext } from "./ui/context";

const home = process.env.HOME ?? "/";
const args = process.argv.slice(2);
const rootArg = args.indexOf("--root");
const root = rootArg >= 0 && rootArg + 1 < args.length ? args[rootArg + 1] : home;
const data = dataDir(home);
const cache = home + "/Library/Caches/com.floodlight.gpuix";
for (const dir of [data, cache + "/icons", cache + "/images"]) ensureDir(dir);

const controller = new Controller(
  { home, root, index: defaultIndexPath(home) },
  loadApps(applicationFolders(home), home),
  new CoreFiles(root, home),
  new SqliteClipStore(data + "/clipboard.sqlite"),
);
const icons = new IconCache(cache + "/icons");
controller.onRelease.push(() => icons.clear());
controller.boot();

render(
  <ServicesContext.Provider value={{ controller, icons, imageDir: cache + "/images" }}>
    <App />
  </ServicesContext.Provider>,
  {
    title: "Floodlight",
    appName: "Floodlight",
    width: PANEL_WIDTH,
    height: SEARCH_HEIGHT,
    resizable: false,
    windowBackground: "transparent",
    titlebarTransparent: true,
    show: false,
    focus: false,
    tabNavigation: false,
  },
);

// render() has opened the window; the panel styling needs it to exist.
const hotkeys = controller.start();
if (args.includes("--bench")) void runBench(controller, hotkeys);
