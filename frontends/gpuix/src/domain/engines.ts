/**
 * Keyword-addressed web search (ADR 0006) and typed web addresses, ported
 * from the Swift `KeywordEngineRegistry` and `DirectLink`. Assistant engines
 * are left out: they need a process runner this frontend does not have yet.
 */
import { ACTION_OPEN, KIND_WEB, Row } from "./row";

export const RANK_DIRECT_LINK = 160000;
export const RANK_KEYWORD_ENGINE = 150000;

export class Engine {
  constructor(
    readonly id: string,
    /** The verb phrase, for the mode token: `Search YouTube`. */
    readonly title: string,
    /** The row title: `YouTube`. */
    readonly name: string,
    /** First is the canonical spelling. */
    readonly keywords: string[],
    readonly template: string,
  ) {}

  host(): string {
    const rest = this.template.slice(this.template.indexOf("//") + 2);
    const host = rest.slice(0, rest.indexOf("/"));
    return host.startsWith("www.") ? host.slice(4) : host;
  }

  url(query: string): string {
    return this.template.split("{query}").join(encodeQuery(query));
  }
}

/** Percent-encodes everything but `A-Z a-z 0-9 - . _ ~`, as the Swift app does. */
export function encodeQuery(query: string): string {
  return encodeURIComponent(query)
    .split("!")
    .join("%21")
    .split("'")
    .join("%27")
    .split("(")
    .join("%28")
    .split(")")
    .join("%29")
    .split("*")
    .join("%2A");
}

export const ENGINES: Engine[] = [
  new Engine("google", "Search Google", "Google", ["g", "google", "!g"], "https://www.google.com/search?q={query}"),
  new Engine(
    "wikipedia",
    "Search Wikipedia",
    "Wikipedia",
    ["wiki", "wikipedia", "!wiki"],
    "https://en.wikipedia.org/wiki/Special:Search?search={query}",
  ),
  new Engine("github", "Search GitHub", "GitHub", ["gh", "github", "!gh"], "https://github.com/search?q={query}"),
  new Engine(
    "stackoverflow",
    "Search Stack Overflow",
    "Stack Overflow",
    ["so", "stackoverflow", "!so"],
    "https://stackoverflow.com/search?q={query}",
  ),
  new Engine("twitter", "Search Twitter/X", "Twitter/X", ["x", "twitter", "!x"], "https://x.com/search?q={query}"),
  new Engine(
    "youtube",
    "Search YouTube",
    "YouTube",
    ["yt", "youtube", "!yt"],
    "https://www.youtube.com/results?search_query={query}",
  ),
];

export const DEFAULT_ENGINE = ENGINES[0];

export function engineById(id: string): Engine {
  for (const engine of ENGINES) if (engine.id === id) return engine;
  return DEFAULT_ENGINE;
}

export function engineForKeyword(keyword: string): Engine | null {
  const key = keyword.toLowerCase();
  for (const engine of ENGINES) if (engine.keywords.indexOf(key) >= 0) return engine;
  return null;
}

function isSpace(c: string): boolean {
  return c === " " || c === "\t" || c === "\n" || c === "\r";
}

/** The query's first whitespace-delimited word and the trimmed rest. */
export class Address {
  constructor(
    readonly keyword: string,
    readonly remainder: string,
  ) {}
}

export function parseAddress(query: string): Address | null {
  let i = 0;
  while (i < query.length && isSpace(query.charAt(i))) i++;
  if (i === query.length) return null;
  let j = i;
  while (j < query.length && !isSpace(query.charAt(j))) j++;
  return new Address(query.slice(i, j), query.slice(j).trim());
}

/** `yt lofi` → the YouTube row for `lofi`. */
export function addressedRow(query: string): Row | null {
  const address = parseAddress(query);
  if (address === null || address.remainder.length === 0) return null;
  const engine = engineForKeyword(address.keyword);
  if (engine === null) return null;
  return engineRow(engine, address.remainder, "keyword-engine:" + engine.id, RANK_KEYWORD_ENGINE);
}

export function engineRow(engine: Engine, query: string, id: string, score: number): Row {
  return new Row(KIND_WEB, id, engine.name, engine.host(), engine.url(query), ACTION_OPEN, [], score);
}

/** The "Search Google" row that ends every non-empty local list. */
export function fallbackRow(query: string): Row {
  return engineRow(DEFAULT_ENGINE, query, "web-search", 0);
}

/** Web mode: every engine, the active one first. */
export function webModeRows(query: string, activeId: string): Row[] {
  const rows: Row[] = [];
  const active = engineById(activeId);
  rows.push(engineRow(active, query, "web-mode:" + active.id, RANK_KEYWORD_ENGINE));
  let position = 1;
  for (const engine of ENGINES) {
    if (engine.id === active.id) continue;
    rows.push(engineRow(engine, query, "web-mode:" + engine.id, RANK_KEYWORD_ENGINE - position));
    position++;
  }
  return rows;
}

// ---- direct links ----------------------------------------------------------

const KNOWN_GTLDS = [
  "app",
  "biz",
  "blog",
  "cloud",
  "com",
  "dev",
  "edu",
  "gov",
  "info",
  "int",
  "mil",
  "net",
  "news",
  "online",
  "org",
  "page",
  "shop",
  "site",
  "store",
  "tech",
  "xyz",
];

function isLetter(c: number): boolean {
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

function isDigit(c: number): boolean {
  return c >= 48 && c <= 57;
}

/** The RFC 3986 scheme `token` starts with, or "". */
function schemeOf(token: string): string {
  if (token.length === 0 || !isLetter(token.charCodeAt(0))) return "";
  for (let i = 1; i < token.length; i++) {
    const c = token.charCodeAt(i);
    if (c === 58) return token.slice(0, i);
    if (!(isLetter(c) || isDigit(c) || c === 43 || c === 45 || c === 46)) return "";
  }
  return "";
}

function namesKnownHost(authority: string): boolean {
  const lastDot = authority.lastIndexOf(".");
  if (lastDot < 0 || authority.startsWith(".") || authority.indexOf("..") >= 0) return false;
  const tld = authority.slice(lastDot + 1);
  if (tld.length === 0) return false;
  for (let i = 0; i < tld.length; i++) if (!isLetter(tld.charCodeAt(i))) return false;
  return tld.length === 2 || KNOWN_GTLDS.indexOf(tld.toLowerCase()) >= 0;
}

/**
 * The row for a query that is itself a web address: `x.com/abc`,
 * `https://localhost:3000`. Only http and https, and never a userinfo part,
 * so a title can never disagree with where Return goes.
 */
export function directLinkRow(query: string): Row | null {
  const token = query.trim();
  if (token.length === 0) return null;
  for (const c of token) if (isSpace(c)) return null;
  if (token.startsWith("/") || token.startsWith("~")) return null;

  const scheme = schemeOf(token);
  let absolute = token;
  let rest = token;
  if (scheme.length > 0) {
    const lower = scheme.toLowerCase();
    if (lower !== "http" && lower !== "https") return null;
    rest = token.slice(scheme.length + 1);
    if (rest.startsWith("//")) rest = rest.slice(2);
  } else {
    absolute = "https://" + token;
  }
  let end = 0;
  while (end < rest.length && "/?#".indexOf(rest.charAt(end)) < 0) end++;
  const authority = rest.slice(0, end);
  if (authority.indexOf("@") >= 0) return null;
  if (scheme.length === 0 && !namesKnownHost(authority)) return null;
  let host = authority;
  const colon = host.lastIndexOf(":");
  if (colon >= 0) host = host.slice(0, colon);
  if (host.length === 0) return null;
  host = host.toLowerCase();
  const title = host.startsWith("www.") ? host.slice(4) : host;
  return new Row(KIND_WEB, "direct-link", title, absolute, absolute, ACTION_OPEN, [], RANK_DIRECT_LINK);
}
