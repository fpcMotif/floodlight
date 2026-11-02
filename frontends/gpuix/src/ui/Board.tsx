/**
 * The clipboard board, 840 × 560 pt: the search bar, the All/Text/Files/Images
 * chips, then an opaque well holding the 360 pt list and the 465 pt inspector,
 * and the 32 pt footer with Paste, Preview and Actions. As in the search
 * panel, only the visible list rows are in the tree.
 */
import { useRef } from "react";
import { countText, entrySubtitle, glyph, MENU_TITLES } from "../domain/board-facts";
import { BOARD_FILTER_TITLES, ClipBoard } from "../domain/clip-board";
import { CLIP_FILE, CLIP_IMAGE, ClipEntry, entryBadge, entryPath, entryTitle, parseHexColor } from "../domain/clip-entry";
import { formatBytes, group } from "../domain/format";
import {
  BOARD_FOOTER_HEIGHT,
  BOARD_INSPECTOR_WIDTH,
  BOARD_LIST_WIDTH,
  BOARD_WELL_CORNER_RADIUS,
  BOARD_WELL_INSET,
  CORNER_RADIUS,
  FILTER_BAR_HEIGHT,
  FONT_CHIP,
  FONT_EMPTY,
  FONT_INPUT,
  FONT_INSPECTOR_LABEL,
  FONT_INSPECTOR_ROW,
  FONT_INSPECTOR_TITLE,
  FONT_KEY_CHIP,
  FONT_ROW_SUBTITLE,
  FONT_ROW_TITLE,
  MAX_VISIBLE_RESULTS,
  RESULT_PADDING,
  RESULT_ROW_CORNER_RADIUS,
  RESULT_ROW_HEIGHT,
  SEARCH_HEIGHT,
} from "../domain/metrics";
import { keyName } from "../domain/panel";
import { windowTop } from "../domain/row-text";
import { useServices } from "./context";
import { FONT, type Theme } from "./theme";

const LIST_HEIGHT = MAX_VISIBLE_RESULTS * RESULT_ROW_HEIGHT + RESULT_PADDING * 2;
const INSPECTOR_IMAGE_HEIGHT = 220;

function BoardBar({ theme }: { theme: Theme }) {
  const { controller } = useServices();
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
      <text style={{ fontSize: FONT_INPUT, fontFamily: FONT, color: theme.secondary }}>⧉</text>
      <input
        value={controller.board.query}
        placeholder="Search clipboard history"
        autoFocus
        onChange={(event) => controller.boardQuery(event.value ?? "")}
        onSubmit={() => controller.boardKey("return")}
        onKeyDown={(event) => {
          const name = keyName(event);
          // Space types into a query; only an empty field turns it into Preview.
          if (name === "space" && controller.board.query.length > 0) return;
          if (controller.boardKey(name)) event.preventDefault();
        }}
        theme={{ caret: theme.accent }}
        style={{ flexGrow: 1, minWidth: 0, fontSize: FONT_INPUT, fontFamily: FONT, color: theme.primary }}
      />
    </div>
  );
}

function BoardFilters({ board, theme }: { board: ClipBoard; theme: Theme }) {
  const { controller } = useServices();
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "row",
        gap: 6,
        alignItems: "center",
        height: FILTER_BAR_HEIGHT,
        paddingLeft: 14,
      }}
    >
      {BOARD_FILTER_TITLES.map((title, f) => (
        <div
          key={title}
          onClick={() => controller.boardKey("cmd+" + (f + 1))}
          style={{
            height: 26,
            paddingLeft: 10,
            paddingRight: 10,
            borderRadius: 13,
            display: "flex",
            alignItems: "center",
            backgroundColor: f === board.filter ? theme.selection : "#00000000",
          }}
        >
          <text style={{ fontSize: FONT_CHIP, fontFamily: FONT, fontWeight: 600, color: theme.primary }}>{title}</text>
        </div>
      ))}
    </div>
  );
}

function EntryRow(props: { entry: ClipEntry; index: number; selected: boolean; now: number; theme: Theme }) {
  const { controller } = useServices();
  const { entry, theme } = props;
  return (
    <div
      onClick={() => controller.selectEntry(props.index)}
      style={{
        display: "flex",
        flexDirection: "row",
        alignItems: "center",
        gap: 10,
        height: RESULT_ROW_HEIGHT,
        flexShrink: 0,
        paddingLeft: 10,
        paddingRight: 10,
        borderRadius: RESULT_ROW_CORNER_RADIUS,
        backgroundColor: props.selected ? theme.selection : "#00000000",
      }}
    >
      <text style={{ width: 20, fontSize: FONT_ROW_TITLE, fontFamily: FONT, color: theme.secondary }}>
        {(entry.isPinned() ? "📌" : "") + glyph(entry)}
      </text>
      <div style={{ display: "flex", flexDirection: "column", flexGrow: 1, minWidth: 0, gap: 2 }}>
        <text
          style={{
            fontSize: FONT_ROW_TITLE,
            fontFamily: FONT,
            fontWeight: 500,
            color: theme.primary,
            whiteSpace: "nowrap",
            textOverflow: "ellipsis",
          }}
        >
          {entryTitle(entry)}
        </text>
        <text
          style={{
            fontSize: FONT_ROW_SUBTITLE,
            fontFamily: FONT,
            color: theme.secondary,
            whiteSpace: "nowrap",
            textOverflow: "ellipsis",
          }}
        >
          {entrySubtitle(entry, controller.sourceName(entry.sourceApp), props.now)}
        </text>
      </div>
    </div>
  );
}

function EntryList({ board, theme }: { board: ClipBoard; theme: Theme }) {
  const top = useRef(0);
  top.current = windowTop(top.current, board.selected, MAX_VISIBLE_RESULTS, board.entries.length);
  const first = top.current;
  if (board.entries.length === 0) {
    return (
      <div style={{ width: BOARD_LIST_WIDTH, display: "flex", alignItems: "center", justifyContent: "center" }}>
        <text style={{ fontSize: FONT_EMPTY, fontFamily: FONT, color: theme.secondary }}>
          {board.query.length > 0 ? "No matches" : "Copy something to start your history"}
        </text>
      </div>
    );
  }
  return (
    <div style={{ width: BOARD_LIST_WIDTH, height: LIST_HEIGHT, padding: RESULT_PADDING }}>
      {board.entries.slice(first, first + MAX_VISIBLE_RESULTS).map((entry, i) => (
        <EntryRow
          key={entry.id}
          entry={entry}
          index={first + i}
          selected={first + i === board.selected}
          now={board.now}
          theme={theme}
        />
      ))}
    </div>
  );
}

function Fact({ label, value, theme }: { label: string; value: string; theme: Theme }) {
  return (
    <div style={{ display: "flex", flexDirection: "row", justifyContent: "space-between" }}>
      <text style={{ fontSize: FONT_INSPECTOR_ROW, fontFamily: FONT, color: theme.secondary }}>{label}</text>
      <text style={{ fontSize: FONT_INSPECTOR_ROW, fontFamily: FONT, color: theme.primary }}>{value}</text>
    </div>
  );
}

function Inspector({ entry, theme }: { entry: ClipEntry | null; theme: Theme }) {
  const { controller, icons, imageDir } = useServices();
  if (entry === null) return <div style={{ width: BOARD_INSPECTOR_WIDTH }} />;
  const facts: Array<[string, string]> = [["Kind", entryBadge(entry)]];
  let body = null;
  if (entry.kind === CLIP_IMAGE) {
    const src = controller.imagePath(entry, imageDir);
    body =
      src.length > 0 ? (
        <img src={src} objectFit="contain" style={{ width: BOARD_INSPECTOR_WIDTH - 40, height: INSPECTOR_IMAGE_HEIGHT }} />
      ) : null;
    facts.push(["Dimensions", entry.imageWidth + " × " + entry.imageHeight], ["Size", formatBytes(entry.imageBytes)]);
  } else if (entry.kind === CLIP_FILE || entryPath(entry).length > 0) {
    const path = entryPath(entry);
    const icon = icons.forPath(path);
    body = icon.length > 0 ? <img src={icon} objectFit="contain" style={{ width: 96, height: 96 }} /> : null;
    facts.push(["Path", path]);
  } else {
    const text = controller.fullText(entry);
    const counts = countText(text);
    const color = entry.contentKind === "color" ? parseHexColor(entry.contentDetail) : null;
    body = (
      <div style={{ display: "flex", flexDirection: "column", gap: 8, flexGrow: 1, minHeight: 0 }}>
        {color !== null ? (
          <div style={{ width: 64, height: 64, borderRadius: 12, backgroundColor: entry.contentDetail }} />
        ) : null}
        <text style={{ fontSize: FONT_INSPECTOR_ROW, fontFamily: FONT, color: theme.primary }}>
          {text.length > 4000 ? text.slice(0, 4000) + "…" : text}
        </text>
      </div>
    );
    facts.push(
      ["Characters", group(counts.characters)],
      ["Words", group(counts.words)],
      ["Lines", group(counts.lines)],
    );
    if (entry.contentDetail.length > 0) facts.push(["Detail", entry.contentDetail]);
  }
  return (
    <div
      style={{
        width: BOARD_INSPECTOR_WIDTH,
        display: "flex",
        flexDirection: "column",
        gap: 12,
        padding: 20,
        overflow: "hidden",
      }}
    >
      <text style={{ fontSize: FONT_INSPECTOR_TITLE, fontFamily: FONT, fontWeight: 600, color: theme.primary }}>
        {entryTitle(entry)}
      </text>
      <div style={{ flexGrow: 1, minHeight: 0, overflow: "hidden" }}>{body}</div>
      <text style={{ fontSize: FONT_INSPECTOR_LABEL, fontFamily: FONT, fontWeight: 600, color: theme.secondary }}>
        Information
      </text>
      {facts.map(([label, value]) => (
        <Fact key={label} label={label} value={value} theme={theme} />
      ))}
    </div>
  );
}

function KeyChip({ keys, title, onClick, theme }: { keys: string; title: string; onClick: () => void; theme: Theme }) {
  return (
    <div onClick={onClick} style={{ display: "flex", flexDirection: "row", gap: 6, alignItems: "center" }}>
      <text style={{ fontSize: FONT_KEY_CHIP, fontFamily: FONT, fontWeight: 600, color: theme.primary }}>{title}</text>
      <div style={{ paddingLeft: 5, paddingRight: 5, borderRadius: 4, backgroundColor: theme.badgeFill }}>
        <text style={{ fontSize: FONT_KEY_CHIP, fontFamily: FONT, color: theme.secondary }}>{keys}</text>
      </div>
    </div>
  );
}

function Footer({ theme }: { theme: Theme }) {
  const { controller } = useServices();
  return (
    <div
      style={{
        height: BOARD_FOOTER_HEIGHT,
        display: "flex",
        flexDirection: "row",
        alignItems: "center",
        justifyContent: "flex-end",
        gap: 18,
        paddingRight: 16,
      }}
    >
      <KeyChip
        keys="↩"
        title="Paste"
        onClick={() => controller.boardKey("return")}
        theme={theme}
      />
      <KeyChip keys="⌘Y" title="Preview" onClick={() => controller.boardKey("cmd+y")} theme={theme} />
      <KeyChip keys="⌘K" title="Actions" onClick={() => controller.boardKey("cmd+k")} theme={theme} />
    </div>
  );
}

function ActionsMenu({ board, theme }: { board: ClipBoard; theme: Theme }) {
  return (
    <div
      style={{
        position: "absolute",
        right: 16,
        bottom: BOARD_FOOTER_HEIGHT + 8,
        width: 200,
        padding: 6,
        borderRadius: 12,
        backgroundColor: theme.well,
        borderWidth: 1,
        borderColor: theme.wellStroke,
      }}
    >
      {board.menuItems().map((item, i) => (
        <div
          key={item}
          style={{
            height: 28,
            paddingLeft: 10,
            borderRadius: 7,
            display: "flex",
            alignItems: "center",
            backgroundColor: i === board.menuSelected ? theme.selection : "#00000000",
          }}
        >
          <text style={{ fontSize: FONT_INSPECTOR_ROW, fontFamily: FONT, color: theme.primary }}>
            {MENU_TITLES.get(item) ?? item}
          </text>
        </div>
      ))}
    </div>
  );
}

export function Board() {
  const { controller, theme } = useServices();
  const board = controller.board;
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
      <BoardBar theme={theme} />
      <BoardFilters board={board} theme={theme} />
      <div
        style={{
          display: "flex",
          flexDirection: "column",
          flexGrow: 1,
          marginLeft: BOARD_WELL_INSET,
          marginRight: BOARD_WELL_INSET,
          marginBottom: BOARD_WELL_INSET,
          borderRadius: BOARD_WELL_CORNER_RADIUS,
          borderWidth: 1,
          borderColor: theme.wellStroke,
          backgroundColor: theme.well,
        }}
      >
        <div style={{ display: "flex", flexDirection: "row", flexGrow: 1, minHeight: 0 }}>
          <EntryList board={board} theme={theme} />
          <div style={{ width: 1, backgroundColor: theme.divider }} />
          <Inspector entry={board.current()} theme={theme} />
        </div>
        <div style={{ height: 1, backgroundColor: theme.divider }} />
        <Footer theme={theme} />
        {board.menuOpen ? <ActionsMenu board={board} theme={theme} /> : null}
      </div>
    </div>
  );
}
