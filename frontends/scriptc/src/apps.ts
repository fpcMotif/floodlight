/**
 * The application catalog: every `.app` bundle in the standard folders, read
 * once at start-up. A few hundred directory entries, so a plain readdir beats
 * any index, and there is nothing to keep warm.
 */
import { readdirSync } from "node:fs";
import { App } from "./session";
import { displayPath } from "./paths";

export function applicationFolders(home: string): string[] {
  return [
    "/Applications",
    "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities",
    "/System/Library/CoreServices/Applications",
    home + "/Applications",
  ];
}

function list(dir: string): string[] {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

/**
 * Lists the bundles in `folders`, one level of sub-folders deep, since
 * vendors group suites that way ("/Applications/Microsoft Office/…"). The
 * first bundle with a given name wins, which is the order the folders are
 * given in: user-installed over system copies.
 */
export function loadApps(folders: string[], home: string): App[] {
  const seen = new Set<string>();
  const apps: App[] = [];
  const add = (dir: string, entry: string): void => {
    const name = entry.slice(0, entry.length - 4);
    if (seen.has(name)) return;
    seen.add(name);
    const path = dir + "/" + entry;
    apps.push(new App(name, path, displayPath(dir, home)));
  };
  for (const dir of folders) {
    for (const entry of list(dir)) {
      if (entry.startsWith(".")) continue;
      if (entry.endsWith(".app")) {
        add(dir, entry);
        continue;
      }
      // Explicit folders like Utilities are listed on their own already.
      if (folders.indexOf(dir + "/" + entry) >= 0) continue;
      const nested = dir + "/" + entry;
      for (const inner of list(nested)) {
        if (inner.endsWith(".app")) add(nested, inner);
      }
    }
  }
  return apps;
}
