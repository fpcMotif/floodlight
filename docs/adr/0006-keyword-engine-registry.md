---
status: accepted
date: 2026-08-09
---

# Represent usable keyword engines as one immutable registry

Floodlight will represent the engines currently usable by Keyword-Addressed Search as one immutable, `Sendable` `KeywordEngineRegistry`. The registry replaces raw engine arrays and lookup dictionaries at module interfaces. It owns engine order, normalized keyword lookup, collision resolution, canonical spelling, the default web engine, and the ordered web-engine subset so local result projection, Web Mode entry, and Tab affordances cannot interpret different engine sets or rules. Collision resolution is first eligible destination wins: addressed results consider every destination, while Web Mode and Tab consider only web destinations.

Assistant availability produces a complete replacement registry rather than mutating lookup state in place. The initial registry contains destinations that are usable without probing external executables; after availability checks complete, Floodlight atomically publishes a registry that also contains the installed assistant engines. Query interpretation remains synchronous and does not cross an actor seam on each keystroke.

The registry does not own Search Session state, Web Mode transitions, result activation, Assistant Run lifecycle, or process execution. `SearchMode` continues to decide mode transitions, while Keyword-Addressed Search supplies the same resolved destination facts to every consumer.

## Considered options

- **Continue passing arrays and dictionaries:** rejected because callers must reproduce ordering, normalization, collision, default-engine, and availability rules, leaving inconsistent configurations representable.
- **Use one immutable resolved registry:** accepted because it hides those invariants behind one synchronous value without adding locks or actor hops to the per-keystroke path.
- **Use an actor that also owns availability and Web Mode:** rejected because it would mix slow executable discovery, pure query interpretation, and Search Session state while making every keystroke asynchronous.

## Consequences

Production callers and tests will cross the same registry interface instead of manufacturing lookup dictionaries. Adding configurable engines later will have one validation and resolution point. The registry must remain a deep module rather than a pass-through dictionary wrapper: callers ask domain questions, while storage shape and collision handling remain private implementation details.
