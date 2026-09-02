# Clipboard Power — design brief (shared by the canvas and the Figma sync)

Everything here is derived from the app's real SwiftUI source. Use these values verbatim.
Dark appearance only (the app's settings surface forces dark; the panel is shown dark on a
dark desktop). System font stack: `-apple-system, "SF Pro Text", "Helvetica Neue", Arial`;
mono: `ui-monospace, "SF Mono", Menlo`. No emoji anywhere. Icons are inline stroke SVGs on a
16/20 px grid (magnifier, clipboard, link, shield, pin, trash, chevron, play, return arrow).

## Tokens

Panel
- Total width 1020 (680 list column + 340 inspector). Height 521 expanded. Radius 30.
- Background: dark glass. Emulate with `#1b1d24` at 96 % plus a 0.5 px border gradient
  `rgba(255,255,255,.35)` top-left to `rgba(255,255,255,.06)` bottom-right. Shadow
  `0 24px 56px rgba(0,0,0,.55), 0 2px 10px rgba(0,0,0,.4)`.
- Search field: height 60, horizontal padding 20, font 24 light, colour `#f2f3f7`,
  placeholder `#7b8291` ("Filter clipboard…"), leading clipboard icon 26 px teal `#4fd1c5`
  inside a chip surface (radius 7, fill `rgba(255,255,255,.14)`), trailing clear circle 18 px.
- Divider under field: 1 px `rgba(255,255,255,.09)`.
- Filter bar: height 40, horizontal padding 14, chips 26 high, radius 13, gap 7; chip text
  11.5 semibold; count 10 semibold in `#9aa4b6`; selected fill `rgba(255,255,255,.14)`,
  unselected `rgba(255,255,255,.055)`. Chips: `All 212`, `Text 148`, `Files 31`,
  `Images 33`, then a hairline gap, then `Pinned 6`, `Receipts 4`, `Snippets 9`.
- Result row: height 58, radius 12, horizontal padding 12, icon tile 38 (radius 9, fill
  tint at 14 %), gap 12; title 15 medium `#f2f3f7`; subtitle 11.5 medium `#9aa4b6`;
  badge 8.5 bold uppercase in `#9aa4b6` on `rgba(255,255,255,.07)` capsule, padding 5/2.
  Selected fill `rgba(255,255,255,.12)`; hover `rgba(255,255,255,.075)`.
  Multi-selected rows: same fill plus a 1 px inset border `rgba(79,209,197,.55)`.
  Redacted (ephemeral) row: title shown as `••••••••••••` with a shield badge `SECRET`
  and subtitle `Expires in 4:12 · Ghostty`.
- Key chip: 11 semibold, min 24×24, padding 0 7, radius 7, fill `rgba(255,255,255,.10)`,
  text `rgba(255,255,255,.82)`.
- Footer / action bar: height 32, horizontal padding 14, fill `rgba(255,255,255,.04)`;
  left text `212 entries` 11 medium `#626b7b`; right: two capsules with 11.5 medium
  text and a 9 semibold key tag on `rgba(255,255,255,.25)` radius 3:
  `Paste to Safari ↵` and `Actions ⌘K`.
- Inspector column: width 340, padding 14, vertical gap 14; section label
  `Information` 12.5 semibold `#9aa4b6`; info rows label 12 `#9aa4b6` / value 12 `#f2f3f7`,
  baseline aligned, min gap 8; content previews: link card mono 12 on
  `rgba(255,255,255,.08)` radius 6 padding 8; code block mono 11.5 line-height 1.35 on
  `rgba(255,255,255,.06)`; colour swatch 72 high radius 12 with 1 px `rgba(255,255,255,.15)`;
  image preview max height 180 radius 12; language badge 10 bold on
  `rgba(255,255,255,.12)` capsule padding 6.
- Accent: teal `#4fd1c5` for the clipboard mode tint; system blue `#4fa2ff` for links.
- Settings window: 760×530, background `#111113` (`rgb(0.065,0.067,0.075)`), header 82 high
  with a 44×44 icon well (radius 11, fill `rgba(184,125,82,.18)`, accent
  `rgb(0.72,0.49,0.32)` = `#b87d52`), title 22 semibold, subtitle 13.5 `#9aa4b6`,
  horizontal padding 24; sections: title 12.5 semibold `#9aa4b6` with 4 px left pad,
  group fill `rgba(255,255,255,.045)` radius 12 with 1 px `rgba(255,255,255,.07)` border,
  content padding 16, gap 14 between sections; rows min 50 high, icon 17 in a 26 wide
  column, title 13.5 semibold, subtitle 11.5 `#9aa4b6`, gap 13; toggles are macOS switches
  tinted `#b87d52`; buttons `.bordered` tinted `#b87d52`; key caps 34 high radius 7 fill
  `rgba(255,255,255,.065)` border `rgba(255,255,255,.12)` 13 semibold; app chips 12 medium
  padding 8/4 on `rgba(255,255,255,.08)` capsule; footer 58 high with a `Done` button
  (13.5 semibold, black text on `#b87d52`, radius 9, 32 high, padding 0 19).

## Artboards (all 1020×521 unless noted)

1. **ClipboardMode** — the resting state. Left: field, chips, seven rows
   (a Safari link selected: "Swift 6.4 Approachable Concurrency — Swift Forums",
   subtitle "Safari · 2 min ago · Copied 3×"; then a Ghostty code snippet; a Finder file
   `品牌绿.png` with IMAGE badge; a screenshot titled `Screenshot` "2 560 × 1 600 · 1 h ago";
   a colour `#3498DB` with a small swatch tile; a redacted SECRET row; a pinned snippet with
   a pin glyph). Right inspector: link card with domain chip `forums.swift.org`, then
   Information: Type Link · Domain forums.swift.org · Characters 71 · Copied Today at 11:02:22
   · Source Safari (16 px icon square). Footer `212 entries` / `Paste to Safari ↵` / `Actions ⌘K`.
2. **ActionsOverlay** — same panel; the inspector column is replaced by the action list
   overlay: a 32-high filter field "Search actions…" then grouped rows (group label 10.5
   semibold `#626b7b` uppercase): Paste → `Paste to Safari ↵`, `Paste as plain text ⇧↵`,
   `Edit before paste ⌘E`; Link → `Open in browser`, `Copy without tracking parameters`,
   `Copy as Markdown link`, `Copy domain`, `Show QR code`; Transform → `Trim whitespace`,
   `Title Case`, `URL encode` … with a `12 more` tail; Organise → `Pin ⇧⌘P`,
   `Add to collection…`, `Delete ⌘⌫`; Manage → `Arm paste stack`, `Manage history…`.
   The highlighted action row uses the selected fill; each row 30 high, text 12.5 medium,
   shortcut as key chips right-aligned.
3. **PasteStack** — multi-select: rows 2–4 multi-selected (teal inset border), footer left
   reads `3 selected · 412 characters`, footer right `Paste 3 joined ↵` and `Actions ⌘K`;
   inspector shows a multi-selection summary card (count, types, separator picker as three
   small chips `Newline` selected / `Comma` / `Tab`) and a primary button `Arm paste stack`.
   Above the panel, a 220×36 menu-bar strip mock: clipboard glyph with a `3` badge and a
   menu `Paste next ⇧⌘V · Cancel Paste Stack`.
4. **SecretGuard** — a redacted row selected; inspector shows a shield card: `Likely secret ·
   GitHub token`, `Kept in memory only · expires in 4:12`, buttons `Reveal` (primary) and
   `Keep` (secondary); Information rows: Type Secret · Source Ghostty · Copied Today at 11:40:05.
   Also the one-time Accessibility hint row above the footer (36 high, fill
   `rgba(79,209,197,.10)`, text 11.5 "Pasting into other apps needs Accessibility access.",
   button `Open System Settings`, close ×).
5. **ClipboardBoard** (760×530) — Settings window, Clipboard pane. Header: icon well +
   `Clipboard` / `History, privacy, and storage on this Mac`. Sections:
   - Overview: four stat tiles in a 4-column grid (Text 148 · 1.2 MB / Files 31 · paths only /
     Images 33 · 48 MB / Pinned 6) and a status line `Capture active · Accessibility granted`
     with two green dots.
   - Capture: row `Record clipboard history` [switch on]; row `Pause capture` with segmented
     `15 min · 1 hour · Until resumed`; row `Return key` picker `Paste to app`; row
     `Clipboard shortcut` key caps `⇧ ⌘ V` and a `Change…` button.
   - Retention: three rows Text `30 days`, Files `30 days`, Images `7 days` (pickers);
     footnote 11.5 `#626b7b` "Pinned entries and collection members are always kept."
   - Privacy: row `Likely secrets` picker `Ephemeral (5 min)`; row `Sensitive apps` chips
     `Ghostty · 2 min`, `1Password`, `+ Add…`; row `Excluded apps` chips `Keychain Access`,
     `Bitwarden`, `+ Add…`.
   - Collections: rows `Pinned 6` (locked), `Receipts 4`, `Snippets 9` with rename/delete
     glyphs, and `+ New collection`.
   - Maintenance: buttons `Clear…`, `Export…`, `Import…`, `Compact`.
   Footer with `Done`.

Canvas layout: artboards 1–4 in one row (gap 100), artboard 5 below (row gap 140).
Sticky notes: one per artboard naming the spec slice it belongs to.
