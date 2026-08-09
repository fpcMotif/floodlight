---
status: accepted
date: 2026-08-09
---

# Put Selected-Result Actions behind a shell performer

Floodlight will move activation, explicit Copy, and Finder reveal policy from `SearchCoordinator` into a main-actor-isolated `SelectedResultActionPerformer` in the macOS shell. The performer owns action meaning, ordering, dismissal decisions, successful application recency, and successful-open Source Selection Learning. `SearchCoordinator` retains selection and passes one immutable `SearchItem`; activation also passes the originating query. Quick Look, search-root changes, indexing, filters, and Settings-window lifetime remain outside the module.

The caller-facing interface has three commands and no returned effect description:

```swift
func activate(_ item: SearchItem, query: String)
func copy(_ item: SearchItem)
func reveal(_ item: SearchItem)
```

The performer directly coordinates existing deep owners: one shared `AssistantRunSession`, `RunningApplicationActivating`, `RecentStore`, and a narrow `@Sendable async` Source Selection Learning closure. It receives required main-actor callbacks for search dismissal and Settings presentation. The application shell wires those callbacks without giving the performer panel, window-controller, `AppDelegate`, or `SearchCoordinator` references.

Mechanical AppKit operations sit behind one cohesive `SelectedResultActionEffects` seam. Its API follows the real framework guarantees: clipboard writing is synchronous and returns `Bool`, opening is `async throws`, and Finder reveal is a synchronous dispatched request without invented completion. The production adapter converts `NSWorkspace` completion handlers to checked continuations; scripted tests observe effects without changing the user clipboard, opening applications, or revealing files.

## Action policy

| Action | Presentation | Successful consequences |
|---|---|---|
| Activate `.copy(value)` | Dismiss only after the clipboard accepts the exact value | None |
| Explicit Copy | Keep search open | None |
| Activate an already-running application | Dismiss after synchronous activation succeeds | Record application recency and report Source Selection Learning |
| Open an application, file, folder, or URL | Dismiss promptly; never reopen automatically after delayed failure | After confirmed completion, record application recency when applicable and report Source Selection Learning |
| Show Floodlight Settings | Dismiss search, then request Settings presentation | None |
| Start Assistant Run | Keep search open | `AssistantRunSession` publishes running, answered, or failed state |
| Reveal a file URL in Finder | Dispatch reveal, then dismiss | None |
| Reveal an unsupported result | Keep search open and do nothing | None |

Each open activation is independent. A later activation does not cancel an earlier intentional open, and every asynchronous operation captures its own immutable item, URL, and originating query. Assistant Run remains latest-wins because its existing session deliberately publishes one replaceable run.

`RecentStore` records only successful application activation because `ApplicationCatalog` is its only ranking consumer. Source Selection Learning is separate and query-specific: every successful `.open` activation is reported, then `SourceSearchEngine` uses its provenance to route or ignore the feedback. Failed opens produce neither signal.

Explicit Copy derives one representation inside the performer: `.copy` uses its exact payload, file URLs use their path, other URLs use their absolute string, Floodlight Settings uses the row title, and an Assistant row uses its completed answer when available or its title otherwise. The effects adapter receives only the final exact string.

## Failure policy

Clipboard failure keeps search visible. Failure to activate an existing application is not final; it falls back to normal Launch Services opening. An asynchronous open error is logged without recording recency or learning and without showing a modal alert or unexpectedly reopening Floodlight. Assistant failures retain their existing inline presentation. Finder reveal cannot report completion, so the performer claims only that the request was dispatched.

## Considered options

- **Keep actions in `SearchCoordinator`:** rejected because selection state, AppKit mechanics, action meaning, asynchronous completion, recency, and learning would continue changing for unrelated reasons in one type.
- **Return effect descriptions for the coordinator to interpret:** rejected because it duplicates the action vocabulary and leaves ordering policy outside the module.
- **Put action planning in `FloodlightEngine`:** rejected because these operations ultimately coordinate AppKit and shell presentation rather than platform-neutral search behavior.
- **Use one protocol per AppKit call:** rejected in favor of one cohesive mechanical-effects seam.
- **Pass all of `SourceSearching`:** rejected because action execution needs only one outbound learning operation and must not gain search, rebuild, or scope authority.
- **Make every effect `async throws`:** rejected because clipboard and Finder APIs do not provide those semantics.
- **Cancel the previous open on each activation:** rejected because separate activations express separate user intent and cancellation may not retract work already handed to Launch Services.
- **Show modal errors or automatically reopen search:** rejected as disruptive product behavior; a future non-modal recovery surface can be designed independently.

## Consequences

`SearchCoordinator` becomes the Search Session owner rather than the interpreter of result actions. Interface-level tests drive the performer through scripted effects and verify exact values, ordering, success/failure consequences, independent opens, Assistant behavior, and unsupported reveal. The AppKit adapter remains intentionally thin and receives a small real-macOS smoke check for clipboard, URL/file/application opening, and Finder reveal because those framework integrations cannot be proven by scripted tests alone.
