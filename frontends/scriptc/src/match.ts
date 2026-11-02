/**
 * Fuzzy matching for short names: application titles, and file names once the
 * core has already picked the candidates.
 *
 * A query matches when its characters appear in order in the name, ignoring
 * case. The score rewards what a launcher user means when they type: a prefix
 * ("saf" → Safari), word starts ("vsc" → Visual Studio Code), and runs of
 * consecutive characters. Gaps and long names cost a little, so the shorter of
 * two equal matches wins.
 */

export class Match {
  constructor(
    readonly score: number,
    /** UTF-16 offsets into the name, ascending, one per query character. */
    readonly positions: number[],
  ) {}
}

const PREFIX = 120;
const WORD_START = 40;
const CONSECUTIVE = 24;
const BASE = 16;
const GAP = 1;

function isWordStart(name: string, lower: string, i: number): boolean {
  if (i === 0) return true;
  const prev = name.charCodeAt(i - 1);
  const cur = name.charCodeAt(i);
  const prevIsSeparator = prev === 32 || prev === 45 || prev === 95 || prev === 46 || prev === 47;
  // camelCase and PascalCase boundaries count: "TextEdit" starts a word at E.
  const camel = cur >= 65 && cur <= 90 && !(prev >= 65 && prev <= 90) && lower.charCodeAt(i) !== cur;
  return prevIsSeparator || camel;
}

/**
 * Scores `name` against an already-lowercased `query`; null when it does not
 * match. Greedy from the left, but it prefers a word-start occurrence of each
 * character over an earlier mid-word one, which is what makes acronyms work.
 */
export function fuzzyMatch(name: string, query: string): Match | null {
  if (query.length === 0) return new Match(0, []);
  const lower = name.toLowerCase();
  // toLowerCase can change length for a few scripts; positions would drift.
  if (lower.length !== name.length) return containsMatch(lower, query);

  const positions: number[] = [];
  let score = 0;
  let from = 0;
  let last = -2;
  for (let q = 0; q < query.length; q++) {
    const ch = query.charCodeAt(q);
    let at = -1;
    let boundary = -1;
    for (let i = from; i < lower.length; i++) {
      if (lower.charCodeAt(i) !== ch) continue;
      if (at < 0) at = i;
      if (i === last + 1) {
        boundary = i;
        break;
      }
      if (isWordStart(name, lower, i)) {
        boundary = i;
        break;
      }
    }
    if (at < 0) return null;
    const pick = boundary >= 0 ? boundary : at;
    score += BASE;
    if (pick === last + 1) score += CONSECUTIVE;
    else if (isWordStart(name, lower, pick)) score += WORD_START;
    if (last >= 0) score -= GAP * (pick - last - 1);
    positions.push(pick);
    last = pick;
    from = pick + 1;
  }
  if (positions[0] === 0 && lower.startsWith(query)) score += PREFIX;
  score -= lower.length - query.length;
  return new Match(score, positions);
}

function containsMatch(lower: string, query: string): Match | null {
  const at = lower.indexOf(query);
  if (at < 0) return null;
  const positions: number[] = [];
  for (let i = 0; i < query.length; i++) positions.push(at + i);
  return new Match(BASE * query.length - at, positions);
}
