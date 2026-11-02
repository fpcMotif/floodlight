/** Path display helpers shared by the app catalog and the file source. */

/** `~` for the home folder, the way Finder and every shell abbreviate it. */
export function displayPath(path: string, home: string): string {
  if (home.length > 1 && (path === home || path.startsWith(home + "/"))) {
    return "~" + path.slice(home.length);
  }
  return path;
}

export function baseName(path: string): string {
  const slash = path.lastIndexOf("/");
  return slash < 0 ? path : path.slice(slash + 1);
}

export function parentPath(path: string): string {
  const slash = path.lastIndexOf("/");
  if (slash < 0) return "";
  return slash === 0 ? "/" : path.slice(0, slash);
}

export function joinPath(root: string, relative: string): string {
  if (relative.length === 0) return root;
  return root.endsWith("/") ? root + relative : root + "/" + relative;
}

/**
 * The frontend's own data folder, apart from the Swift app's, so the two can
 * be tried side by side: the index and the clipboard history live here.
 */
export function dataDir(home: string): string {
  if (process.platform === "darwin") return home + "/Library/Application Support/" + BUNDLE_ID;
  const xdg = process.env.XDG_DATA_HOME ?? "";
  return (xdg.length > 0 ? xdg : home + "/.local/share") + "/floodlight-gpuix";
}

export const BUNDLE_ID = "com.floodlight.gpuix";
