## Problem Statement

Clipboard History in Floodlight now captures text, files, and images, searches them, and shows a rich Clipboard Inspector. But the moment a user finds the entry they want, the experience stops short of what a clipboard manager is for:

- **Return does not paste.** It writes the entry back to the pasteboard and dismisses. The user still has to switch focus and press ⌘V. The action bar reads `Paste to <App> ↵`, but the name shown is the entry's *source* app, not where the paste will land, and no paste happens.
- **`Actions ⌘K` is a label, not a feature.** The button silently runs Copy. There is no per-type action list, no paste-as-plain-text, no transforms, no edit-before-paste.
- **Reaching the board takes typing.** Clipboard mode is entered by typing `clip` and pressing Tab. There is no dedicated shortcut, so the most common "I copied that a minute ago" moment costs four keystrokes before searching starts.
- **History is a flat, noisy list.** The same string copied ten times over a week appears ten times. There is no way to say "links from Safari yesterday" or "images this week". Pins are the only organisation.
- **Secrets are only protected when the source app cooperates.** Password managers set concealed pasteboard types, but tokens copied from a terminal, a `.env` file, or a web console are recorded in plain text for 30 days.
- **Management is thin.** The settings pane offers one toggle, one retention picker, a bundle-identifier text field for exclusions, and "Clear history". There is no picture of what is stored, no per-type retention, no pause, no export, no collections.

Raycast, Paste, Pastebot, and Maccy set the expectation that the selected entry is *pasted where you were*, that ⌘K opens a keyboard-driven action list shaped by the entry's type, and that a manager offers a real board for organising and pruning history. Floodlight has the capture, storage, search, and inspector foundations for all of it and stops one step short on each.

## Solution

Turn Clipboard History from a viewer into a paste tool and give it a management board, in six coherent slices that can ship as separate pull requests:

1. **Paste Target and direct entry.** A second global shortcut (default ⇧⌘V, configurable) opens Floodlight straight into Clipboard mode. When the Search surface appears, Floodlight records the **Paste Target**: the application that was frontmost at that moment. Return pastes the selected entry into the Paste Target by writing it to the pasteboard, dismissing, and synthesising ⌘V. This requires the Accessibility permission; without it, Return keeps today's copy-and-dismiss behaviour and the action bar truthfully reads `Copy ↵` with a one-time hint. ⇧Return pastes as plain text. The action bar names the real target: `Paste to Safari ↵`.
2. **Clipboard Actions (⌘K).** A searchable, keyboard-driven action list over the selected entry, composed from the entry's type: links get Open, Copy without tracking parameters, Copy as Markdown link, Copy domain, Show QR code; colours get Copy as HEX / `rgb()` / `hsl()` / SwiftUI literal; code and JSON get Pretty print, Minify, Copy as escaped string; images get Recognize text, Save to Downloads, Copy as PNG/JPEG, Open in Preview; files get Open, Open With…, Reveal, Copy path, Copy name; any text gets **Paste Transforms** (plain text, trim, case changes, sort/unique lines, join lines, URL/Base64 encode and decode, wrap in quotes) and **Edit before paste**. Every entry gets Pin, Delete, Add to collection, and Arm paste stack. Data detectors surface Mail, Maps, and phone actions when an address, email, or number is present.
3. **Smarter history.** Repeated copies merge into one entry that moves to the top and shows `Copied 4×`. Search understands scopes: `from:safari`, `is:link`, `is:pinned`, `on:yesterday`, `after:2026-08-25`, `in:receipts`. Entries copied from an iPhone via Universal Clipboard and screenshots from the system capture tool are labelled.
4. **Secret Guard.** Likely secrets (API keys, tokens, JWTs, private keys, card numbers) are detected on device. By default they are **ephemeral**: kept only in memory, redacted in the list and inspector, revealable on request, and gone after five minutes or on quit. The policy can be changed to *skip entirely* or *record normally*. Apps can be marked *sensitive* so everything they copy is ephemeral.
5. **Paste Stack and multi-select.** ⇧↑/⇧↓ or ⌘-click selects several entries. Return pastes them joined by a separator; "Arm paste stack" makes each later press of the clipboard shortcut paste the next entry directly, with the menu bar showing the remaining count.
6. **Clipboard Board.** A Configuration pane that shows what is stored (entries and bytes by type, capture state, Accessibility state), controls capture (pause for 15 minutes, 1 hour, or until resumed; Return behaviour; shortcut), retention per type, privacy (Secret Guard policy, sensitive apps, excluded apps chosen with a picker), collections (create, rename, delete), and maintenance (clear by type or age, export, import, compact).

Everything stays on the Mac. Nothing uses the network.

## User Stories

### Direct entry and pasting

1. As a Floodlight user, I want a global shortcut that opens Clipboard mode directly, so that reaching my history costs one keystroke instead of typing `clip` and Tab.
2. As a Floodlight user, I want to change the clipboard shortcut in Settings, so that it never collides with a shortcut an app I use already owns.
3. As a Floodlight user, I want Return to paste the selected entry into the app I was using, so that I do not have to switch back and press ⌘V.
4. As a Floodlight user, I want the action bar to name the app I will paste into, so that I know where the entry will land before pressing Return.
5. As a Floodlight user who has not granted Accessibility, I want Return to still copy and dismiss, and the action bar to say `Copy ↵`, so that the panel never promises a paste it cannot perform.
6. As a Floodlight user who has not granted Accessibility, I want a single, dismissible hint that pasting needs the permission, with a button that opens the right System Settings pane, so that I can enable it without hunting.
7. As a Floodlight user, I want ⇧Return to paste the plain-text form of the entry, so that formatting from a web page or document does not follow me into a code editor.
8. As a Floodlight user, I want ⌥Return and ⌘C to keep copying without dismissing, so that the shortcuts I already learned do not change meaning.
9. As a Floodlight user, I want the paste to leave the pasteboard holding what I pasted, so that a second ⌘V in the target app pastes the same thing.
10. As a Floodlight user, I want Floodlight's own paste writes to never be recorded as new entries, so that pasting does not create duplicates.
11. As a Floodlight user, I want pasting into a password field or an app that ignores synthetic keystrokes to fail safely (entry on the pasteboard, no stray characters), so that a failed paste is never destructive.
12. As a Floodlight user, I want Return in Clipboard mode to be configurable between "Paste to app" and "Copy to clipboard", so that I can keep the old behaviour if I prefer it.
13. As a Floodlight user, I want the clipboard shortcut, when the panel is already open in another mode, to switch to Clipboard mode without losing my selection, so that the shortcut is always safe to press.

### Clipboard Actions

14. As a Floodlight user, I want ⌘K to open a list of actions for the selected entry, so that I can do more than paste without leaving the keyboard.
15. As a Floodlight user, I want to type to filter the action list and press Return to run the highlighted action, so that a long list never slows me down.
16. As a Floodlight user, I want Escape in the action list to close it and return to the entry list, so that opening it by mistake costs nothing.
17. As a Floodlight user, I want each action to show its shortcut when it has one, so that I learn the direct keys over time.
18. As a Floodlight user, I want the action list to differ by entry type, so that I only see actions that apply.
19. As a Floodlight user with a link selected, I want Open in browser, Copy without tracking parameters, Copy as Markdown link, Copy domain, and Show QR code, so that link chores take one keystroke.
20. As a Floodlight user with a colour selected, I want Copy as HEX, `rgb()`, `hsl()`, SwiftUI `Color`, and `NSColor`, so that I can move a colour between design and code without converting by hand.
21. As a Floodlight user with JSON or code selected, I want Pretty print, Minify, and Copy as escaped string, so that I can reshape a payload before pasting.
22. As a Floodlight user with an image selected, I want Recognize text, so that text inside a screenshot becomes pasteable and searchable.
23. As a Floodlight user with an image selected, I want Save to Downloads, Copy as PNG, Copy as JPEG, and Open in Preview, so that a captured image can leave the clipboard without a detour.
24. As a Floodlight user with a file selected, I want Open, Open With…, Reveal in Finder, Copy path, and Copy name, so that a copied file is as actionable as a search result.
25. As a Floodlight user with text containing an email address, I want a Compose mail action, so that a copied address becomes a draft in one step.
26. As a Floodlight user with text containing a street address, I want Open in Maps, so that a copied address becomes directions.
27. As a Floodlight user with text containing a phone number, I want Call or Copy number, so that a copied number is dialled without retyping.
28. As a Floodlight user, I want Pin, Delete, and Add to collection in every action list, so that organising happens where I am looking.
29. As a Floodlight user, I want Delete to remove the entry immediately with no confirmation and move the selection to the next entry, so that pruning is fast; and I want Undo delete available for a few seconds, so that a slip is recoverable.
30. As a Floodlight user, I want direct shortcuts for the most common actions (⇧⌘P pin, ⌘⌫ delete, ⌘E edit, ⇧⌘C copy as plain text), so that I rarely need to open the list at all.

### Paste Transforms and editing

31. As a Floodlight user, I want a Transforms group in the action list (plain text, trim whitespace, collapse whitespace, lowercase, UPPERCASE, Title Case, Sentence case, camelCase, snake_case, kebab-case, join lines, sort lines, unique lines, reverse lines, wrap in quotes, wrap in backticks, URL encode, URL decode, Base64 encode, Base64 decode, JSON pretty, JSON minify, strip tracking parameters), so that I can reshape text before it lands.
32. As a Floodlight user, I want the inspector to preview the transformed text while a transform is highlighted, so that I can see the result before committing.
33. As a Floodlight user, I want to choose whether a transform pastes or copies (Return pastes, ⌥Return copies), so that transforms follow the same rule as entries.
34. As a Floodlight user, I want a transform that fails (invalid JSON, invalid Base64) to say so and leave the entry unchanged, so that a bad transform is never silent.
35. As a Floodlight user, I want to press ⌘E to edit the selected text in place, then Return to paste the edited text, so that a near-right snippet becomes right without a round trip through an editor.
36. As a Floodlight user, I want edits to paste without creating a new history entry unless I explicitly copy them, so that my history is not polluted with drafts.

### Smarter history

37. As a Floodlight user, I want copying the same text again to move its existing entry to the top instead of adding a duplicate, so that history stays short and honest.
38. As a Floodlight user, I want a merged entry to show how many times it was copied and when it was last copied, so that heavily reused snippets are easy to spot.
39. As a Floodlight user, I want a merged entry to keep its pin and collections, so that organisation survives re-copying.
40. As a Floodlight user, I want `from:safari` (or any app name fragment) to restrict results to that source app, so that I can find "that link from Safari".
41. As a Floodlight user, I want `is:link`, `is:code`, `is:color`, `is:text`, `is:file`, `is:folder`, `is:image`, `is:video`, `is:pinned`, `is:secret`, `is:screenshot`, and `is:remote` to filter by content type or state, so that type filtering is not limited to four chips.
42. As a Floodlight user, I want `on:today`, `on:yesterday`, `on:2026-08-30`, `after:2026-08-25`, and `before:2026-09-01` to filter by copy time, so that I can scope history to a day or range.
43. As a Floodlight user, I want `in:<collection>` to restrict results to a collection, so that a collection is searchable as well as browsable.
44. As a Floodlight user, I want scope tokens to combine with free text and with each other, so that `from:ghostty is:code after:2026-08-30 sqlite` works.
45. As a Floodlight user, I want an unknown or malformed scope token to be treated as plain text rather than an error, so that typing a colon never empties the list.
46. As a Floodlight user, I want the filter chip row to include a Pinned chip and one chip per collection, so that the most useful scopes are one click or ⌘-digit away.
47. As a Floodlight user, I want entries pasted from my iPhone or iPad via Universal Clipboard to be labelled `from iPhone`, so that I know where they came from.
48. As a Floodlight user, I want images captured with the system screenshot tool to be titled `Screenshot` and to be filterable with `is:screenshot`, so that screenshots are distinguishable from other images.
49. As a Floodlight user, I want text recognised from an image to be searchable, so that a screenshot of an error message can be found by its words.

### Secret Guard

50. As a Floodlight user, I want tokens, API keys, JWTs, private keys, and card numbers copied from any app to be detected on device, so that secrets are protected even when the source app does not mark them.
51. As a Floodlight user, I want detected secrets to be ephemeral by default: held only in memory, redacted in the list and inspector, and removed after five minutes or on quit, so that a secret never reaches disk.
52. As a Floodlight user, I want a shield badge on ephemeral entries and a countdown in the inspector, so that I understand why an entry looks different and when it will vanish.
53. As a Floodlight user, I want to reveal a redacted secret with an explicit action, so that I can still paste it while it lives.
54. As a Floodlight user, I want to choose a Secret Guard policy of Ephemeral, Skip entirely, or Record normally, so that the default matches my risk tolerance.
55. As a Floodlight user, I want to mark apps as sensitive so that everything copied from them is ephemeral with a configurable lifetime, so that a terminal or a secrets manager never leaves a trace.
56. As a Floodlight user, I want a false positive (a long hash I need to keep) to be fixable with a "Keep" action that persists the entry, so that the guard never traps content I own.
57. As a Floodlight user, I want the existing concealed and transient pasteboard markers to keep skipping capture entirely, so that password managers behave exactly as before.

### Paste Stack and multi-select

58. As a Floodlight user, I want ⇧↓ and ⇧↑ to extend the selection across several entries, so that I can act on a group.
59. As a Floodlight user, I want ⌘-click to toggle an entry in or out of the selection, so that non-adjacent groups are possible.
60. As a Floodlight user, I want the inspector to summarise a multi-selection (count, total characters, types), so that I know what I am about to paste.
61. As a Floodlight user, I want Return with several entries selected to paste them joined by a separator (newline by default; comma, space, tab, or blank line chosen from the action list), so that I can fill a list or a row in one paste.
62. As a Floodlight user, I want "Arm paste stack" so that each later press of the clipboard shortcut pastes the next selected entry directly, so that I can fill a form field by field without reopening the panel.
63. As a Floodlight user, I want the menu bar icon to show the remaining stack count and offer Cancel Paste Stack, so that an armed stack is visible and abortable.
64. As a Floodlight user, I want the stack to disarm automatically after the last entry, so that the clipboard shortcut returns to opening the panel.
65. As a Floodlight user, I want the summon shortcut (⌘Space) to keep opening the panel normally while a stack is armed, so that arming never locks me out of search.

### Clipboard Board

66. As a Floodlight user, I want a Clipboard pane in Settings that shows how many entries and how many megabytes I hold per type, so that I can see what the feature costs me.
67. As a Floodlight user, I want the pane to show whether capture is active or paused and whether Accessibility is granted, so that a non-working paste has a visible cause.
68. As a Floodlight user, I want to pause capture for 15 minutes, 1 hour, or until I resume, and to see a paused indicator in the menu bar, so that private work stays private.
69. As a Floodlight user, I want to resume capture from the menu bar and from the pane, so that resuming is as easy as pausing.
70. As a Floodlight user, I want separate retention for text, files, and images (defaults 30, 30, and 7 days, or forever), so that large images do not live as long as small snippets.
71. As a Floodlight user, I want pinned entries and collection members to be exempt from retention, so that organising something is the same as keeping it.
72. As a Floodlight user, I want to choose excluded apps from a picker (running apps or an application chooser) instead of typing bundle identifiers, so that exclusions are usable by anyone.
73. As a Floodlight user, I want to see excluded and sensitive apps with their icons and names, so that the lists are readable.
74. As a Floodlight user, I want to create, rename, and delete collections from the pane, so that organising does not require the panel.
75. As a Floodlight user, I want deleting a collection to keep its entries in history, so that a collection is a view, not a container.
76. As a Floodlight user, I want to clear history by type, by age (older than a day, week, month), or entirely, so that I can prune without losing everything.
77. As a Floodlight user, I want Clear to ask for confirmation once and report what was removed, so that a large deletion is deliberate.
78. As a Floodlight user, I want to export history as a folder with a JSON file and images, so that I can archive or move it.
79. As a Floodlight user, I want to import such a folder and have duplicates merged, so that restoring never doubles my history.
80. As a Floodlight user, I want a Compact action after large deletions so that the database file shrinks, so that disk space returns.
81. As a Floodlight user, I want the pane to open from the ⌘K list ("Manage history…") and from the menu bar, so that management is reachable from where I notice the need.
82. As a Floodlight user, I want the pane to record the clipboard shortcut with the same recorder used for the summon shortcut, so that both shortcuts feel like one system.

### Trust, performance, and accessibility

83. As a Floodlight user, I want every keystroke in Clipboard mode to stay within the existing latency budgets with 10,000 entries, so that the new scopes and merging never make search feel slower.
84. As a Floodlight user, I want OCR, QR generation, and transforms to run off the main thread and never block typing, so that heavy actions do not freeze the panel.
85. As a Floodlight user, I want every action, chip, and badge to have an accessibility label, so that VoiceOver users can drive the board.
86. As a Floodlight user, I want the paste to never leave a half-typed sequence in the target app, so that a failure mode is "nothing happened", never garbage.
87. As a Floodlight user, I want none of these features to use the network, so that the privacy promise of the app holds.

## Implementation Decisions

### Vocabulary (additions to the domain glossary)

- **Paste Target**: the application frontmost at the moment the Search surface was shown, captured by Application Presentation and published to the Search Session. Nil when Floodlight itself was frontmost.
- **Paste Delivery**: the mechanical act of putting a payload on the pasteboard, dismissing the Search surface, and synthesising ⌘V in the Paste Target. Requires Accessibility trust; degrades to copy-and-dismiss.
- **Clipboard Action**: one named, keyboard-runnable operation on the current clipboard selection, with an optional direct shortcut and a group (Paste, Transform, Link, Colour, Code, Image, File, Detected, Organise, Manage).
- **Paste Transform**: a pure, total function from text to text (or a failure) in a fixed catalogue.
- **Paste Stack**: an ordered list of entry identities armed for sequential Paste Delivery, advanced by the clipboard shortcut.
- **Clipboard Collection**: a named, ordered set of entry identities. Pinned is a built-in collection with fixed identity.
- **Secret Guard**: on-device detection of likely secrets at capture, plus the policy applied to them.
- **Ephemeral Entry**: a Clipboard Entry that lives only in the in-memory window, is redacted by default, and expires at a fixed time.
- **Clipboard Query**: a parsed search: free text plus scope tokens (`from`, `is`, `in`, `on`, `after`, `before`).
- **Clipboard Board**: the Configuration pane for Clipboard History management.

### Engine (FloodlightEngine)

- **Clipboard Query parsing** lives in the engine as a pure parser producing free text plus typed scopes. Unknown tokens are literal text. The store's `search` accepts the parsed query. `from:` matches source app bundle identifier or display-name fragment case-insensitively; date scopes use the caller's calendar and `now`. `on:` accepts `today`, `yesterday`, and ISO dates.
- **Content classification moves to the engine.** The pure parts of today's inspector classification (link, colour, code, JSON, local path shape, video/image extension) become an engine classifier run at record time; the result is stored per entry as a content type, plus the extracted domain for links. The inspector keeps only what needs the filesystem or AppKit (file existence, sizes, thumbnails, app names). `is:` scopes query the stored content type.
- **Duplicate merging replaces consecutive-only dedupe.** The store keeps a content hash per entry (SHA-256 of kind plus text for text and files, the existing image hash for images) with a unique index. Recording an existing hash updates `last_copied_at`, increments `copy_count`, moves the entry to the top of the recent window, and preserves pin, collections, `first_copied_at`, and identity. The entry exposes `firstCopiedAt`, `lastCopiedAt`, and `copyCount`; `createdAt` is retained as an alias of `firstCopiedAt` for existing callers. Ordering of unpinned entries becomes `last_copied_at` descending.
- **Collections** are two new tables: collections (identity, name, sort order, creation time) and membership (collection identity, entry identity, added time), with a unique pair index. Pinned remains the `pinned_at` column and is presented as a built-in collection. Deleting a collection removes memberships only. Retention pruning skips pinned entries and collection members.
- **Secret Guard detection** is a pure engine rule set: ordered regex rules with names (AWS access key, GitHub token, generic `sk-` key, Slack token, JWT, PEM private key block, Google API key, Stripe key), a Luhn check for 13–19 digit runs, and a high-entropy rule (length ≥ 32, Shannon entropy above a threshold, no whitespace, not a URL, not hex-only under 64 characters). Rules are tested against the adversarial corpus for false positives. The final rule table is refined by research prompt R4.
- **Ephemeral lifetime.** `record` gains a lifetime parameter: persistent or ephemeral until a date. Ephemeral entries are held only in the in-memory recent window, are never written to SQLite or FTS, carry `isEphemeral` and `expiresAt`, and are removed by an `expire(now:)` pass the capture service calls on every poll and at launch. Search over the in-memory window covers them. Quitting discards them.
- **Per-kind retention** replaces the single retention value: text, files, images each `days(n)` or `forever`. `prune(retention:now:)` takes the triple.
- **Recognised text** is a nullable column indexed by the existing FTS triggers alongside the entry text, so OCR results are searchable without a second index. Remote-clipboard and screenshot flags are stored as booleans set by the capture service.
- **Paste Transforms** are an engine catalogue: identity, display name, group, and a total function `(String) -> Result<String, TransformFailure>`. Case transforms are Unicode-aware; `strip tracking parameters` removes a fixed list (`utm_*`, `fbclid`, `gclid`, `mc_cid`, `mc_eid`, `igshid`, `ref_src`) and leaves other parameters intact; JSON transforms use Foundation serialisation with sorted keys off; Base64 decode requires valid UTF-8 output.
- **Export and import** are engine operations: export writes a JSON document (schema version, entries with metadata, collections, memberships) plus an images directory named by hash; import reads the same shape and records through the normal merge path so duplicates fold. Ephemeral entries are never exported.
- **Migration** stays idempotent `ALTER TABLE ADD COLUMN` guarded by `PRAGMA user_version`; existing rows get content hashes, content types, `first_copied_at = created_at`, `last_copied_at = created_at`, `copy_count = 1` in one migration pass. Pre-existing duplicates are merged in that pass, keeping the newest identity and the pinned state if any copy was pinned.
- **Compact** runs `VACUUM` off the query path and is only offered from the Clipboard Board.
- The engine remains free of UI frameworks, detached tasks, and query-path disk reads, as the architecture rules require. Search over 10,000 entries with scopes keeps the existing 2 ms median budget; a second budgeted test covers the merge path on record.

### Shell: Paste Target and Paste Delivery

- **Application Presentation captures the Paste Target** when the Search surface is shown, from the frontmost application at that instant, and publishes it (bundle identifier, display name, icon) to the Search Session. The action bar reads it from there. The label is `Paste to <Name> ↵` when a target exists and Accessibility is trusted, otherwise `Copy ↵`.
- **Global Hot-Key Registration owns two registrations**: summon and clipboard. Each has its own identifier and callback; the clipboard callback asks Application Presentation to show the Search surface in Clipboard mode (equivalent to the `clip` Tab transition with an empty query) or, when a Paste Stack is armed, performs the next Paste Delivery instead. The glossary entry for Global Hot-Key Registration changes from "one shortcut" to "Floodlight's system-wide shortcuts".
- **Selected-Result Action Performer** gains `paste(_ item, into target, form)` alongside `activate`, `copy`, and `reveal`. Its policy: write the payload with the own-write marker; if a Paste Target exists and trust is granted, dismiss, then request one Paste Delivery through the effects seam; if delivery reports failure, leave the pasteboard as written and do nothing else. Without trust or target, behave exactly as activate does today. The performer never records recency or Source Selection Learning for pastes.
- **Selected-Result Action Effects** gains three mechanical operations: `isAccessibilityTrusted() -> Bool`, `requestAccessibilityTrust()`, and `pasteIntoFrontmostApplication() async -> Bool` (post ⌘V key down/up via a CGEvent on the HID tap after the panel has resigned, with a short bounded wait; returns false when Secure Input is enabled or posting fails). The production adapter is the only place that touches CGEvent. Research prompt R1 settles the delay strategy; the spec fixes the contract, not the milliseconds.
- **Plain-text paste** writes only the string type. For images and files, ⇧Return pastes the display name or path as text.
- **Return behaviour** is a preference: Paste to app (default) or Copy to clipboard. It applies only in Clipboard mode.
- **Accessibility hint** is a one-time inline row above the action bar with an Open System Settings button; dismissing it sets a preference. The Clipboard Board shows the state permanently.

### Shell: Clipboard Actions and Transforms

- **Clipboard Actions are composed by a pure shell composer** from the selection: entry kind and content type, detector results, multi-selection count, pin state, ephemeral state, and Paste Target presence. It returns ordered groups of actions with identity, title, optional shortcut, and an enablement reason. The composer has no AppKit dependencies so it is table-testable.
- **The action list is a Result Projection state**, not a new window: the Search Session enters an *action list* sub-state in which the query field filters actions, ↑/↓ moves through actions, Return runs one, and Escape returns to the entry list with selection intact. The list renders as an overlay inside the inspector column so the panel size does not change.
- **Running an action** routes through the performer for anything that touches the pasteboard, opens, or reveals; through the coordinator for store mutations (pin, delete, collection membership, keep); and through a new `ClipboardMediaEffects` seam for OCR (Vision text recognition with automatic language detection), QR generation (Core Image), Save to Downloads, and JPEG re-encoding. That seam is scripted in tests and real only in the adapter.
- **Transform preview**: while a transform action is highlighted, the inspector shows the transformed text (or the failure message) in place of the entry text, computed on a background task with the entry's text captured immutably.
- **Edit before paste** turns the inspector text into an editable field; Return pastes the field's text through the performer with the same form rules; Escape restores. Edited text is not recorded unless the user copies it with ⌥Return.
- **Undo delete** keeps the last deleted entry (with image payload) in the Search Session for eight seconds and re-records it through the store on undo, preserving identity.
- **Data detectors** run on selection change off the main actor using Foundation's detector for links, emails, phone numbers, addresses, and dates, on entries up to the text cap. Results feed the composer. Calendar creation is out of scope; dates produce Copy only.

### Shell: multi-select and Paste Stack

- **Selection becomes a set with an anchor**: the Search Session holds the primary selection (as today) plus an ordered set of additional entry identities. ⇧↑/⇧↓ extend from the anchor; ⌘-click toggles. Any non-shift navigation collapses the set. Result Publication carries the set so rows render a multi-selected state.
- **Multi-paste** joins entries in selection order with the chosen separator, treating files and images by their text form. The separator preference defaults to newline.
- **Paste Stack** is held by Application Presentation (it outlives the panel): an ordered list of entry identities and a cursor. Arming stores the identities; each clipboard-shortcut press pops the next entry, performs Paste Delivery, and updates the menu bar badge; the stack disarms when empty, on Cancel from the menu bar, or if an entry no longer exists. Arming requires trust; otherwise the action is disabled with the reason.

### Shell: capture

- **Clipboard Capture** gains: Secret Guard evaluation for text (policy from preferences), sensitive-app rule (bundle identifier plus lifetime), pause state with an expiry instant on a monotonic clock, remote-clipboard detection, screenshot detection, and the expiry pass for ephemeral entries on every poll. Pause is exposed as `pause(for:)`, `pause()`, `resume()`, and `pauseState` for the menu bar and Board.
- **Universal Clipboard and screenshot detection** use pasteboard type markers confirmed by research prompt R3; until confirmed, the flags are computed by a single function that is trivially replaceable.

### Shell: Clipboard Board

- **The Board is a new main-actor observable model** over the store, capture service, hot-key registration, and the trust check. It exposes overview counts and byte totals by kind, capture and pause state, trust state, retention triple, Secret Guard policy, sensitive and excluded app lists (bundle identifier, display name, icon resolved through the existing app icon cache), collections, and the maintenance operations. All mutations go through it so the pane view stays declarative.
- **The pane replaces the current clipboard section** in the settings presentation of the onboarding/configuration surface and reuses its section, row, toggle, picker, and key-cap styling. Sections: Overview, Capture, Retention, Privacy, Collections, Maintenance. App pickers use the running-application list and an application chooser.
- **Menu bar** gains: capture paused indicator (symbol variant), Pause submenu, Resume, Paste Stack remaining count, Cancel Paste Stack, Open Clipboard Board.

### Keyboard map (Clipboard mode)

| Key | Meaning |
|---|---|
| ⇧⌘V (global, configurable) | Open Clipboard mode; or paste next from armed stack |
| Return | Paste to Paste Target (or copy and dismiss when not trusted / preference) |
| ⇧Return | Paste as plain text |
| ⌥Return / ⌘C | Copy without dismissing (unchanged) |
| ⇧⌘C | Copy as plain text without dismissing |
| ⌘K | Open Clipboard Actions |
| ⌘E | Edit before paste |
| ⇧⌘P | Pin / unpin |
| ⌘⌫ | Delete (undo for eight seconds with ⌘Z) |
| ⇧↑ / ⇧↓ | Extend selection |
| ⌘1–⌘4 | All / Text / Files / Images (unchanged) |
| ⌘5 | Pinned; further collections via `in:` or click |
| Space, ⌘Y, ⌘R, ⌘⌥Return | Quick Look and reveal (unchanged) |

### Delivery slices (each a pull request, in order)

1. Paste Target, Paste Delivery, clipboard hotkey, plain-text paste, truthful action bar, Accessibility hint, Return preference.
2. Clipboard Actions composer and overlay, direct shortcuts, Paste Transforms with preview, Edit before paste, Undo delete, link/colour/code/file actions, data detector actions.
3. Store: content classification at record time, duplicate merging with counts, Clipboard Query scopes, collections, Pinned chip and collection chips.
4. Secret Guard, Ephemeral Entries, sensitive apps, per-kind retention.
5. Multi-select, multi-paste, Paste Stack, menu bar additions.
6. Clipboard Board pane, pause, export, import, compact, app pickers; then image actions (OCR, QR, save, JPEG) behind the media effects seam.

Slices 1 to 3 are independent of 4 to 6 except where noted; slice 2 must land before 5.

## Testing Decisions

A good test drives a seam the way the product does and asserts what a user could observe: what ended up on the pasteboard, which rows were published, what the store returns, what the action bar says. Tests do not inspect private state, do not mock the store (the in-memory store is real), and do not touch the user's real pasteboard, hot keys, or Accessibility.

Seams, all existing unless marked new:

- **Clipboard History Store (engine, direct).** Merge-on-record with counts and preserved pins and collections; Clipboard Query scopes over source, type, date, collection, and free text; ephemeral entries visible in search, absent from disk, gone after expiry; per-kind retention exempting pinned and collection members; export then import into an empty store yields the same entries; migration of a pre-existing database with duplicates. Property tests: any sequence of records and merges keeps pinned-first ordering and `copyCount` equal to the number of records of that hash; parser never throws on the adversarial corpus and round-trips scope-free text unchanged. Performance: scoped search over 10,000 entries within the existing 2 ms median; record-with-merge within a new budget, both printed as `FLOODLIGHT_BENCH` lines. Prior art: the existing store, property, and performance test suites.
- **Engine catalogues, table-driven.** Paste Transforms (each transform against a fixed table of inputs, including failures, Unicode case, and tracking-parameter stripping); Secret Guard rules (positives per rule, the adversarial corpus and a URL/hash corpus as negatives, the Luhn table). Prior art: calculator and fuzzy matcher adversarial and differential suites.
- **Selected-Result Action Performer with scripted effects.** Paste with trust and target: exact write, dismissal, one delivery request, no recency and no learning; without trust: write and dismiss, no delivery; delivery failure: nothing further; plain-text form for text, files, and images; transform-then-paste and transform-then-copy; multi-paste joining with each separator; edit-then-paste. Prior art: the existing performer tests and scripted effects double.
- **Search Coordinator in Clipboard mode.** Hotkey entry publishes history rows with the Paste Target in the publication; action-list sub-state filtering, running, and escaping; direct shortcuts; multi-select extension and collapse; undo delete restores identity; Pinned and collection chips; scope queries reach the store; ephemeral rows render redacted until revealed. Prior art: the existing Clipboard-mode coordinator tests.
- **Clipboard Capture with the scripted pasteboard.** Secret Guard policies (ephemeral, skip, record); sensitive-app lifetime; pause with timed expiry using an injected clock; remote and screenshot flags; own-write marker still skipped; expiry pass removes ephemeral entries. Prior art: the existing capture service tests.
- **Clipboard Inspector snapshot.** Multi-selection summary; transform preview; detector results; recognised text display; redaction. Prior art: the existing inspector tests.
- **Clipboard Board model (new seam).** Overview totals from a seeded store; retention and policy round-trip through preferences; collection create, rename, delete; clear by type and age reports counts; export and import through a temporary directory. It is the only new seam, placed at the model so the pane view stays untested beyond rendering.
- **Rendering.** The action overlay, multi-selected rows, redacted rows, the Board pane, and the menu bar states render through the existing renderer and hosting-view suites without crashing, in both appearances, including the hostile-title corpus.
- **Real-macOS smoke checks**, run by hand on a Mac and listed in the Mac test plan: Paste Delivery into TextEdit, Safari, Terminal, and a password field; Secure Input behaviour; hotkey collisions; OCR on a real screenshot; TCC persistence across rebuilds of the installed bundle.

## Out of Scope

- Cloud sync, sharing, or any network access (including fetching link titles or favicons).
- Global interception of ⌘V (event taps) for sequential paste; the Paste Stack advances only through the clipboard shortcut.
- Snippet placeholders and text expansion.
- Calendar event creation from detected dates.
- In-panel video playback and image editing.
- OCR languages beyond what Vision's automatic detection provides; no custom models.
- Apple Foundation Models summaries or titles (research prompt R12 records the option for a later spec).
- Changing the two-column layout, sizes, or inspector visual design beyond the action overlay, badges, and hint row.

## Further Notes

- Issue #57 covers the rich inspector and two-column layout; this spec builds on it and leaves its visual decisions intact. The action bar's current `Paste to <App>` and `Actions ⌘K` labels are the two promises this spec makes true.
- The design canvas and the Figma file for this spec show the Clipboard mode panel with the action overlay, the paste-stack and multi-select states, the redacted secret state, the Accessibility hint, and the Clipboard Board pane. They follow the app's current tokens (680 pt panel plus 340 pt inspector, 30 pt panel radius, 12 pt row radius, 15/11.5/8.5 pt type ramp, key-chip and filter-chip surfaces).
- Research prompts R1 to R12 in the repository scratch folder list the facts an implementing agent should confirm on a Mac before slices 1, 4, and 6: paste delivery timing, Accessibility deep link on macOS 26, pasteboard privacy markers, secret-rule precision, OCR latency, and hotkey defaults.
- Existing tests that encode consecutive-only deduplication and single-value retention change meaning under this spec; they are to be rewritten, not deleted.
