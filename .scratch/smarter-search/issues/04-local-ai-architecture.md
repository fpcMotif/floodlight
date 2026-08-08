# Local AI search architecture

Type: grilling
Status: open
Blocked by: 01

## Question

Given the recommended local-AI stack (ticket 01), decide how the three AI jobs sit in Floodlight's architecture:

- **Intent router**: does it run per-keystroke, per-pause, or only when heuristics are uncertain? How does its verdict reorder results in `SearchCoordinator` without adding latency to the non-AI path?
- **Natural-language file search**: what is the contract between the model and FFF — model emits structured query terms/filters (date ranges, file kinds, paths) that FFF executes? How is it triggered (always-on for long queries? a prefix? a mode)?
- **Explore/answer mode**: is it a separate panel state (chat-like) or inline results? What can it read (file names only vs. content) — privacy line for a local model is softer, but content access still meets macOS permissions?
- **Model lifecycle**: bundled vs. downloaded on first use, storage location, memory residency for an always-running launcher, and the settings surface (on/off, model choice).
- **Minimum OS / hardware**: accept the research ticket's implication (e.g. macOS 26 + Apple Silicon for Foundation Models) or bundle a model to keep macOS 14?

Resolve via /grilling and /domain-modeling with the user; the answer is the AI section of the final spec.
