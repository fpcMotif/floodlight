/** Result filter chips and their counts, from the Swift `SearchResultFilter`. */
import { KIND_APP, KIND_FILE, KIND_FOLDER, Row } from "./row";

export const FILTER_ALL = 0;
export const FILTER_APPS = 1;
export const FILTER_FILES = 2;
export const FILTER_FOLDERS = 3;
export const FILTER_PDFS = 4;
export const FILTER_IMAGES = 5;
export const FILTER_COUNT = 6;

export const FILTER_TITLES = ["All", "Apps", "Files", "Folders", "PDFs", "Images"];
/** Always shown; the rest only while they have rows or are selected. */
export const PRIMARY_FILTERS = 4;

const IMAGE_EXTENSIONS = ["avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp"];

export function isImageExtension(ext: string): boolean {
  return IMAGE_EXTENSIONS.indexOf(ext) >= 0;
}

export function filterIncludes(filter: number, row: Row): boolean {
  if (filter === FILTER_ALL) return true;
  if (filter === FILTER_APPS) return row.kind === KIND_APP;
  if (filter === FILTER_FILES) return row.kind === KIND_FILE;
  if (filter === FILTER_FOLDERS) return row.kind === KIND_FOLDER;
  if (filter === FILTER_PDFS) return row.kind === KIND_FILE && row.ext === "pdf";
  return row.kind === KIND_FILE && isImageExtension(row.ext);
}

/** One count per filter, over the same publication the rows come from. */
export function filterCounts(rows: Row[]): number[] {
  const counts: number[] = [];
  for (let f = 0; f < FILTER_COUNT; f++) counts.push(0);
  for (const row of rows) {
    for (let f = 0; f < FILTER_COUNT; f++) if (filterIncludes(f, row)) counts[f]++;
  }
  return counts;
}

/** The chips to draw: the primary four, then any dynamic one with rows. */
export function visibleFilters(counts: number[], selected: number): number[] {
  const out: number[] = [];
  for (let f = 0; f < FILTER_COUNT; f++) {
    if (f < PRIMARY_FILTERS || counts[f] > 0 || f === selected) out.push(f);
  }
  return out;
}
