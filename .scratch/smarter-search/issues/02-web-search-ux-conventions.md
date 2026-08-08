# Launcher web-search UX conventions

Type: research
Status: resolved

## Question

How do the established launchers route "I want the web, not local results", so Floodlight's routing spec can adopt proven conventions instead of inventing them? Survey primary sources (official docs/manuals) for:

- **Raycast**: fallback commands, quicklinks, search-engine keywords, the ⌘K action-on-any-query pattern.
- **Alfred**: default fallbacks list, custom web searches with `{query}`, keyword triggers.
- **LaunchBar**: search templates, instant-send patterns.
- **PowerToys Run / Flow Launcher**: action keywords like `??`/`!bang`, plugin-based web search.
- **DuckDuckGo bangs** as a syntax convention (`!yt`, `!gh`).

For each: (a) how the user *explicitly* invokes web search (prefix keyword? trailing hotkey? dedicated result row?), (b) how *implicit* fallback works when local results are empty or weak, (c) how multiple search engines are configured and addressed, (d) any hotkey conventions for "search web for current query" (e.g. ⌘Return / Shift+Return).

Deliver: a findings doc with a short per-launcher summary and a distilled list of conventions Floodlight should copy, adapt, or skip — input for the "Web-search routing spec" grilling ticket.

## Answer

Every surveyed launcher converges on the same three-layer model: (1) explicit keyword-prefix engines backed by a `{query}`-style URL template (Alfred Web Search, Flow `{q}` sources, LaunchBar `*`/`%s` templates); (2) an implicit, user-curated fallback list that receives the raw query when local results are empty — Raycast Fallback Commands and Alfred Fallback Searches, with Alfred also offering "append at end of weak results"; (3) an always-available escape hatch — Spotlight's own convention is a chord (⌘B) that web-searches the typed query. DDG bangs (`!yt`) are the portable alias syntax worth accepting on top of word keywords; PowerToys' cryptic sigils (`??`) and browser-delegated engine choice are the anti-patterns to skip. Flow Launcher validates a ranked (not hard-pinned) global web row via its Google `*` source.

Full findings with source URLs: [research/web-search-ux-conventions.md](../research/web-search-ux-conventions.md)
