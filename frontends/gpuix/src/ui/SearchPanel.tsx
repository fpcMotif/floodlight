/**
 * The search panel: the 60 pt bar, then the filter chips and at most seven
 * rows. Only the visible rows are ever in the tree, so a keystroke commits
 * seven rows' worth of mutations however long the result list is.
 */
import { useRef } from "react";
import { FILTER_TITLES, visibleFilters } from "../domain/filters";
import {
  CORNER_RADIUS,
  FILTER_BAR_HEIGHT,
  FONT_CHIP,
  FONT_EMPTY,
  FONT_INPUT,
  FONT_ROW_SUBTITLE,
  MAX_VISIBLE_RESULTS,
  NOTICE_HEIGHT,
  RESULT_PADDING,
  RESULT_ROW_HEIGHT,
  SEARCH_HEIGHT,
  SEARCH_ICON_SIZE,
} from "../domain/metrics";
import { keyName } from "../domain/panel";
import { windowTop } from "../domain/row-text";
import { MODE_WEB } from "../domain/session";
import { engineById } from "../domain/engines";
import { useServices } from "./context";
import { ResultRow } from "./ResultRow";
import { FONT, type Theme } from "./theme";

function SearchBar({ theme }: { theme: Theme }) {
  const { controller } = useServices();
  const session = controller.session;
  const web = session.mode === MODE_WEB;
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "row",
        alignItems: "center",
        gap: 12,
        height: SEARCH_HEIGHT,
        paddingLeft: 20,
        paddingRight: 20,
      }}
    >
      <text style={{ fontSize: SEARCH_ICON_SIZE, fontFamily: FONT, color: theme.secondary }}>⌕</text>
      {web ? <ModeChip title={engineById(session.engineId).name} theme={theme} /> : null}
      <input
        value={session.query}
        placeholder={web ? "Search the web" : "Floodlight Search"}
        autoFocus
        onChange={(event) => controller.setQuery(event.value ?? "")}
        onSubmit={() => controller.panelKey("return")}
        onKeyDown={(event) => {
          if (controller.panelKey(keyName(event))) event.preventDefault();
        }}
        theme={{ caret: theme.accent }}
        style={{ flexGrow: 1, minWidth: 0, fontSize: FONT_INPUT, fontFamily: FONT, color: theme.primary }}
      />
    </div>
  );
}

function ModeChip({ title, theme }: { title: string; theme: Theme }) {
  return (
    <div
      style={{
        paddingLeft: 10,
        paddingRight: 10,
        height: 26,
        borderRadius: 13,
        display: "flex",
        alignItems: "center",
        backgroundColor: theme.accent,
      }}
    >
      <text style={{ fontSize: FONT_CHIP, fontFamily: FONT, fontWeight: 600, color: "#ffffff" }}>{title}</text>
    </div>
  );
}

function FilterBar({ theme }: { theme: Theme }) {
  const { controller } = useServices();
  const s = controller.session;
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "row",
        alignItems: "center",
        gap: 6,
        height: FILTER_BAR_HEIGHT,
        paddingLeft: 14,
        paddingRight: 14,
      }}
    >
      {visibleFilters(s.counts, s.filter).map((f) => {
        const selected = f === s.filter;
        return (
          <div
            key={f}
            onClick={() => controller.panelKey("cmd+" + (f + 1))}
            style={{
              display: "flex",
              flexDirection: "row",
              gap: 5,
              alignItems: "center",
              height: 26,
              paddingLeft: 10,
              paddingRight: 10,
              borderRadius: 13,
              backgroundColor: selected ? theme.selection : "#00000000",
            }}
          >
            <text style={{ fontSize: FONT_CHIP, fontFamily: FONT, fontWeight: 600, color: theme.primary }}>
              {FILTER_TITLES[f]}
            </text>
            <text style={{ fontSize: FONT_CHIP, fontFamily: FONT, color: theme.secondary }}>{String(s.counts[f])}</text>
          </div>
        );
      })}
    </div>
  );
}

function Notice({ theme }: { theme: Theme }) {
  const { controller } = useServices();
  const message = controller.fda.notice(controller.grantBundle().split("/").pop()?.replace(/\.app$/, "") ?? "");
  return (
    <div
      onClick={() => controller.panelKey("cmd+g")}
      style={{ height: NOTICE_HEIGHT, display: "flex", alignItems: "center", paddingLeft: 20, paddingRight: 20 }}
    >
      <text style={{ fontSize: FONT_ROW_SUBTITLE, fontFamily: FONT, color: theme.secondary }}>{message}</text>
    </div>
  );
}

function Results({ theme }: { theme: Theme }) {
  const { controller } = useServices();
  const s = controller.session;
  const top = useRef(0);
  top.current = windowTop(top.current, s.selected, MAX_VISIBLE_RESULTS, s.rows.length);
  const first = top.current;
  const visible = s.rows.slice(first, first + MAX_VISIBLE_RESULTS);
  const height = MAX_VISIBLE_RESULTS * RESULT_ROW_HEIGHT + RESULT_PADDING * 2;
  if (s.rows.length === 0) {
    return (
      <div style={{ height, display: "flex", alignItems: "center", justifyContent: "center" }}>
        <text style={{ fontSize: FONT_EMPTY, fontFamily: FONT, color: theme.secondary }}>No results</text>
      </div>
    );
  }
  const now = Date.now() / 1000;
  return (
    <div
      onScroll={(event) => {
        const dy = event.deltaY ?? 0;
        if (Math.abs(dy) >= 1) controller.panelKey(dy > 0 ? "down" : "up");
      }}
      style={{ height, display: "flex", flexDirection: "column", padding: RESULT_PADDING }}
    >
      {visible.map((row, i) => (
        <ResultRow
          key={row.id}
          row={row}
          index={first + i}
          selected={first + i === s.selected}
          topHit={first + i === 0 && s.topHit() !== null}
          now={now}
          theme={theme}
        />
      ))}
    </div>
  );
}

export function SearchPanel() {
  const { controller, theme } = useServices();
  const hasQuery = controller.session.query.length > 0;
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        width: "100%",
        height: "100%",
        borderRadius: CORNER_RADIUS,
        backgroundColor: theme.surface,
      }}
    >
      <SearchBar theme={theme} />
      {controller.noticeShown() ? <Notice theme={theme} /> : null}
      {hasQuery ? (
        <>
          <div style={{ height: 1, backgroundColor: theme.divider }} />
          <FilterBar theme={theme} />
          <Results theme={theme} />
        </>
      ) : null}
    </div>
  );
}
