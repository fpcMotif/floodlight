/**
 * A port of the core's matcher (`core/src/match.zig`), so an app name and a
 * file name that match a query equally well get the same score, and the app
 * bonus is the only thing that puts the app first.
 *
 * The core works on bytes and folds ASCII case only; this works on UTF-16
 * code units with the same fold, which is the same result for every name
 * the core can score.
 */

const SCORE_MATCH = 16;
const BONUS_BOUNDARY = 8;
const BONUS_NAME_START = 12;
const BONUS_CAMEL = 7;
const BONUS_CONSECUTIVE = 5;
const BONUS_IN_NAME = 3;
const PENALTY_GAP_START = 3;
const PENALTY_GAP_EXTEND = 1;
const BONUS_EXACT_NAME = 120;
const BONUS_NAME_PREFIX = 40;

function lower(c: number): number {
  return c >= 65 && c <= 90 ? c + 32 : c;
}

function isUpper(c: number): boolean {
  return c >= 65 && c <= 90;
}

function isLower(c: number): boolean {
  return c >= 97 && c <= 122;
}

function isSeparator(c: number): boolean {
  return c === 47 || c === 45 || c === 95 || c === 46 || c === 32;
}

function startsWithFold(hay: string, needle: string): boolean {
  for (let i = 0; i < needle.length; i++) {
    if (lower(hay.charCodeAt(i)) !== needle.charCodeAt(i)) return false;
  }
  return true;
}

/**
 * The core's score for `needle` (already lowercase) in `hay`, or -1 when it
 * does not match. Scores are never negative for a real match of a name.
 */
export function coreScore(hay: string, needle: string): number {
  if (needle.length === 0) return 0;
  if (needle.length > hay.length) return -1;

  let j = 0;
  let end = -1;
  for (let i = 0; i < hay.length; i++) {
    if (lower(hay.charCodeAt(i)) === needle.charCodeAt(j)) {
      j++;
      if (j === needle.length) {
        end = i;
        break;
      }
    }
  }
  if (end < 0) return -1;

  // The backward pass picks the tightest window ending at `end`.
  let start = end;
  j = needle.length;
  for (let i = end; i >= 0; i--) {
    if (lower(hay.charCodeAt(i)) === needle.charCodeAt(j - 1)) {
      j--;
      if (j === 0) {
        start = i;
        break;
      }
    }
  }

  let total = 0;
  let prev = -1;
  j = 0;
  for (let k = start; k <= end; k++) {
    const c = hay.charCodeAt(k);
    if (lower(c) !== needle.charCodeAt(j)) continue;
    let bonus = 0;
    if (k === 0) bonus = BONUS_NAME_START;
    else if (isSeparator(hay.charCodeAt(k - 1))) bonus = BONUS_BOUNDARY;
    else if (isUpper(c) && isLower(hay.charCodeAt(k - 1))) bonus = BONUS_CAMEL;
    if (j === 0) bonus *= 2;
    let s = SCORE_MATCH + bonus + BONUS_IN_NAME;
    if (prev >= 0) {
      const gap = k - prev - 1;
      if (gap === 0) s += BONUS_CONSECUTIVE;
      else s -= PENALTY_GAP_START + (Math.min(gap, 32) - 1) * PENALTY_GAP_EXTEND;
    }
    total += s;
    prev = k;
    j++;
    if (j === needle.length) break;
  }

  if (hay.length >= needle.length && startsWithFold(hay, needle)) {
    const exact = hay.length === needle.length || hay.charCodeAt(needle.length) === 46;
    total += exact ? BONUS_EXACT_NAME : BONUS_NAME_PREFIX;
  }
  return total;
}

/** Space-separated terms, lowercased; empty terms dropped. */
export function queryTerms(query: string): string[] {
  const out: string[] = [];
  for (const term of query.toLowerCase().split(" ")) {
    if (term.length > 0) out.push(term);
  }
  return out;
}

/** The sum over every term, or -1 when any term misses, as the core sums. */
export function scoreAllTerms(name: string, terms: string[]): number {
  let total = 0;
  for (const term of terms) {
    const s = coreScore(name, term);
    if (s < 0) return -1;
    total += s;
  }
  return total;
}
