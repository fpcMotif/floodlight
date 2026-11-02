/** Where the file index lives and when it is rebuilt; shared by both frontends. */
import { existsSync, mkdirSync } from "node:fs";
import { CoreFiles } from "./files";
import {
  fls_file_age_s,
  fls_index_build_async,
  fls_index_build_result,
  fls_index_open,
  fls_index_poll,
} from "./native";
import { dataDir, parentPath } from "./paths";

/** Older than this, the index is rebuilt in the background at start-up. */
const STALE_SECONDS = 15 * 60;

export function defaultIndexPath(home: string): string {
  return dataDir(home) + "/files.flix";
}

export function ensureDir(dir: string): void {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

/**
 * Opens the index file if there is one, and starts a background rebuild when
 * it is missing or stale. True while that rebuild runs.
 */
export function prepareIndex(index: string, root: string, files: CoreFiles): boolean {
  const age = fls_file_age_s(index);
  if (age >= 0) {
    const count = fls_index_open(index);
    files.entries = count >= 0 ? count : -1;
  }
  if (age >= 0 && age < STALE_SECONDS && files.entries >= 0) return false;
  return rebuildIndex(index, root);
}

/** Starts a background rebuild now, e.g. after a Full Disk Access grant. */
export function rebuildIndex(index: string, root: string): boolean {
  ensureDir(parentPath(index));
  return fls_index_build_async(root, index) > 0;
}

/** Swaps in a finished background build. True once the build is over. */
export function absorbBuild(index: string, files: CoreFiles): boolean {
  if (fls_index_poll() !== 2) return false;
  // A failed rebuild keeps whatever index was already open.
  if (fls_index_build_result() < 0) return true;
  const count = fls_index_open(index);
  if (count >= 0) files.entries = count;
  return true;
}
