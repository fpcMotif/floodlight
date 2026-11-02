/** Where the file index lives and when it is rebuilt. */
import { existsSync, mkdirSync } from "node:fs";
import { dataDir, parentPath } from "../domain/paths";
import { CoreFiles } from "./core-files";
import { fileAgeSeconds, indexBuildAsync, indexOpen, native } from "./native";

/** Older than this, the index is rebuilt in the background at start-up. */
const STALE_SECONDS = 15 * 60;

export function defaultIndexPath(home: string): string {
  return dataDir(home) + "/files.flix";
}

export function ensureDir(dir: string): void {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

/**
 * Opens the index file if there is one, so search works the moment the app
 * starts, and starts a background rebuild when it is missing or stale. True
 * while that rebuild runs.
 */
export function prepareIndex(index: string, root: string, files: CoreFiles): boolean {
  const age = fileAgeSeconds(index);
  if (age >= 0) {
    const count = indexOpen(index);
    files.entries = count >= 0 ? count : -1;
  }
  if (age >= 0 && age < STALE_SECONDS && files.entries >= 0) return false;
  return rebuildIndex(index, root);
}

/** Starts a background rebuild now, e.g. after a Full Disk Access grant. */
export function rebuildIndex(index: string, root: string): boolean {
  ensureDir(parentPath(index));
  return indexBuildAsync(root, index) > 0;
}

/**
 * Swaps in a finished background build, on the JS thread, so no search can
 * be reading the old mapping as it closes. True once the build is over.
 */
export function absorbBuild(index: string, files: CoreFiles): boolean {
  if (native.fls_index_poll() !== 2) return false;
  // A failed rebuild keeps whatever index was already open.
  if (native.fls_index_build_result() < 0) return true;
  const count = indexOpen(index);
  if (count >= 0) files.entries = count;
  return true;
}
