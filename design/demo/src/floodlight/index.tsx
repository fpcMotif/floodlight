import { Braces, Calculator, Calendar, CornerDownLeft, FileText, Folder, Image, Link, Map, Music, NotebookText, Palette, Search, type LucideIcon } from 'lucide-react'
import { Bar, Collapse, Stage, Text, type Act, type Layout } from '../kit'
import './floodlight.css'

// Floodlight's panel under its own light. Type "cal": Calendar is the top
// hit and the list narrows. Down moves the selection with no animation, as
// the app does. The clipboard hot key swaps the well for the board, Down
// lands on a copied color, Esc returns to an empty search (the loop).

type S = { query: string; view: 'search' | 'board'; sel: number }

const initial: S = { query: '', view: 'search', sel: 0 }
const poster: S = { query: 'cal', view: 'search', sel: 0 }

type Row = { id: string; icon: LucideIcon; hue: string; title?: string; sub?: string; w: number; sw: number }

const ROWS: Row[] = [
  { id: 'calendar', icon: Calendar, hue: 'red', title: 'Calendar', sub: '/System/Applications', w: 0, sw: 0 },
  { id: 'calculator', icon: Calculator, hue: 'amber', title: 'Calculator', sub: '/System/Applications', w: 0, sw: 0 },
  { id: 'notes', icon: NotebookText, hue: 'amber', w: 48, sw: 118 },
  { id: 'maps', icon: Map, hue: 'green', w: 40, sw: 118 },
  { id: 'music', icon: Music, hue: 'red', w: 46, sw: 118 },
  { id: 'folder', icon: Folder, hue: 'blue', w: 36, sw: 96 },
  { id: 'file', icon: FileText, hue: 'gray', w: 112, sw: 214 },
  { id: 'chart', icon: Image, hue: 'cyan', w: 148, sw: 236 },
]

// Which rows answer each query, in the order the app ranks them.
function shown(q: string): string[] {
  if (q === '') return ['notes', 'calendar', 'maps', 'music', 'calculator']
  if (q === 'c') return ['calendar', 'calculator', 'music', 'folder', 'chart']
  return ['calendar', 'calculator', 'folder', 'file', 'chart']
}

const CHIPS = [
  { label: 'All', w: 14 },
  { label: 'Apps', w: 8 },
  { label: 'Files', w: 8 },
]

type Entry = { icon: LucideIcon; hue: string; label?: string; w: number; sw: number }
const ENTRIES: Entry[] = [
  { icon: FileText, hue: 'gray', label: 'Ship the board before Friday', w: 0, sw: 58 },
  { icon: Palette, hue: 'purple', label: '#3478F6', w: 0, sw: 64 },
  { icon: Link, hue: 'blue', w: 132, sw: 70 },
  { icon: Braces, hue: 'cyan', w: 118, sw: 58 },
  { icon: Image, hue: 'gray', w: 86, sw: 96 },
  { icon: FileText, hue: 'gray', w: 140, sw: 64 },
]

async function script(a: Act<S>) {
  await a.wait(1000)
  a.mark('type')
  await a.type('query', 'cal', { interval: 170 })
  await a.wait(1100)
  a.mark('down')
  await a.key('down')
  await a.set({ sel: 1 })
  await a.wait(1300)
  a.mark('board')
  await a.key('alt+shift+c')
  await a.set({ view: 'board', query: '', sel: 0 })
  await a.wait(2000)
  a.mark('color')
  await a.key('down')
  await a.set({ sel: 1 })
  await a.wait(2400)
  a.mark('back')
  await a.key('esc')
  await a.set({ view: 'search', query: '', sel: 0 })
  await a.wait(1300)
}

function Tile({ icon: I, hue, big }: { icon: LucideIcon; hue: string; big?: boolean }) {
  return (
    <span className="fl-tile" data-hue={hue} data-big={big || undefined}>
      <I size={big ? 18 : 15} strokeWidth={2} />
    </span>
  )
}

function Enter({ show }: { show: boolean }) {
  return (
    <span className="fl-enter" data-show={show || undefined}>
      <CornerDownLeft size={12} strokeWidth={2.25} />
    </span>
  )
}

function SearchWell({ s }: { s: S }) {
  const vis = shown(s.query)
  const top = s.query ? vis[0] : ''
  return (
    <div className="fl-page" data-show={s.view === 'search' || undefined}>
      <div className="fl-bar">
        <span className="fl-heads">
          <Text className="fl-head" data-show={!s.query || undefined}>Suggestions</Text>
          <span className="fl-head fl-chips" data-show={!!s.query || undefined}>
            {CHIPS.map((c, i) => (
              <span key={c.label} className="fl-chip" data-selected={i === 0 || undefined}>
                <Text>{c.label}</Text>
                <Bar w={c.w} h={5} tone={3} />
              </span>
            ))}
          </span>
        </span>
      </div>
      <div className="fl-list">
        {ROWS.map((r) => {
          const at = vis.indexOf(r.id)
          const big = top === r.id
          return (
            <Collapse key={r.id} className="fl-filter" open={at >= 0} style={{ order: at < 0 ? 99 : at }}>
              <div className="fl-row" data-selected={at === s.sel || undefined} data-top={big || undefined}>
                <Tile icon={r.icon} hue={r.hue} big={big} />
                <span className="fl-text">
                  {r.title ? <Text className="fl-title">{r.title}</Text> : <Bar w={r.w} h={8} tone={5} />}
                  <span className="fl-sub">
                    {r.sub ? <Text>{r.sub}</Text> : <Bar w={r.sw} h={6} tone={3} />}
                    {r.id === 'calendar' && <Text className="fl-tophit" data-show={big || undefined}>Top Hit</Text>}
                  </span>
                </span>
                <Enter show={at === s.sel} />
              </div>
            </Collapse>
          )
        })}
      </div>
    </div>
  )
}

function Board({ s, layout }: { s: S; layout: Layout }) {
  const compact = layout === 'compact'
  return (
    <div className="fl-page" data-show={s.view === 'board' || undefined}>
      <div className="fl-bar">
        <span className="fl-chips">
          {CHIPS.map((c, i) => (
            <span key={c.label} className="fl-chip" data-selected={i === 0 || undefined}>
              <Text>{i === 1 ? 'Text' : i === 2 ? 'Images' : c.label}</Text>
              <Bar w={c.w - 4} h={5} tone={3} />
            </span>
          ))}
        </span>
      </div>
      <div className="fl-split">
        <div className="fl-entries">
          {ENTRIES.map((e, i) => (
            <div key={i} className="fl-row" data-selected={s.sel === i || undefined}>
              <Tile icon={e.icon} hue={e.hue} />
              <span className="fl-text">
                {e.label ? <Text className="fl-title fl-clamp">{e.label}</Text> : <Bar w={compact ? Math.round(e.w * 0.6) : e.w} h={8} tone={5} />}
                <span className="fl-sub">
                  <Bar w={compact ? Math.round(e.sw * 0.7) : e.sw} h={6} tone={3} />
                </span>
              </span>
              <Enter show={s.sel === i} />
            </div>
          ))}
        </div>
        <div className="fl-inspector">
          <div className="fl-preview">
            <div className="fl-layer" data-show={s.sel === 0 || undefined}>
              <Text className="fl-preview-text" wrap>Ship the board before Friday</Text>
            </div>
            <div className="fl-layer fl-layer-color" data-show={s.sel === 1 || undefined}>
              <span className="fl-swatch" />
              <Text className="fl-preview-text fl-mono">#3478F6</Text>
            </div>
          </div>
          <div className="fl-info">
            <Text className="fl-info-head">Information</Text>
            {[
              [44, 36, 36],
              [30, 28, 34],
              [66, 18, 52],
              [42, 84, 84],
            ].map(([l, v0, v1], i) => (
              <div key={i} className="fl-info-row">
                <span className="fl-info-label">
                  <Bar w={l} h={6} tone={3} />
                </span>
                <span className="fl-info-val">
                  <Bar className="fl-v" data-show={s.sel === 0 || undefined} w={v0} h={6} tone={5} />
                  <Bar className="fl-v" data-show={s.sel === 1 || undefined} w={v1} h={6} tone={5} />
                </span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

export default function FloodlightDemo() {
  return (
    <Stage width={760} height={440} compact={{ below: 560, width: 358, height: 400 }} initial={initial} poster={poster} script={script} theme="dark" keys="bottom" className="fl-stage">
      {(s, _rect, layout) => (
        <div className="fl-desk" data-layout={layout}>
          <div className="fl-light" />
          <div className="fl-panel">
            <div className="fl-search">
              <Search className="fl-glass" size={19} strokeWidth={2.25} />
              <span className="fl-input">
                {s.query && <span className="fl-query">{s.query}</span>}
                <span key={s.query + s.view} className="fl-caret" />
                <span className="fl-ghost" data-show={(s.view === 'search' && s.query === 'cal') || undefined}>endar</span>
                <span className="fl-placeholders" data-hidden={!!s.query || undefined}>
                  <span className="fl-placeholder" data-show={s.view === 'search' || undefined}>Floodlight</span>
                  <span className="fl-placeholder" data-show={s.view === 'board' || undefined}>Filter clipboard</span>
                </span>
              </span>
            </div>
            <div className="fl-well">
              <SearchWell s={s} />
              <Board s={s} layout={layout} />
              <div className="fl-footer">
                <Bar w={52} h={6} tone={3} />
                <span className="fl-spacer" />
                <span className="fl-action">
                  <span className="fl-heads">
                    <Text className="fl-head" data-show={s.view === 'search' || undefined}>Open</Text>
                    <Text className="fl-head" data-show={s.view === 'board' || undefined}>Paste</Text>
                  </span>
                  <span className="fl-glyph">
                    <CornerDownLeft size={9} strokeWidth={2.5} />
                  </span>
                </span>
                <Bar w={64} h={18} r={9} tone={2} />
              </div>
            </div>
          </div>
        </div>
      )}
    </Stage>
  )
}
