---
status: accepted
date: 2026-08-08
---

# Put Assistant Run lifecycle behind AssistantRunSession

Floodlight will move activated assistant execution from `SearchCoordinator` into a deep `AssistantRunSession` module in `FloodlightEngine`. The module owns process invocation, replacement and cancellation, stale-completion rejection, error translation, row ownership, and one coherent optional `AssistantRun` publication. `SearchCoordinator` decides when Search Session events start or cancel an Assistant Run. ADR 0005 supersedes this decision's original AppKit ownership: selected-result copying now belongs to `SelectedResultActionPerformer` and its mechanical effects adapter.

`AssistantRunSession` is a main-actor observable model because its finite running, answered, and failed states directly drive SwiftUI. The subprocess runner remains asynchronous and Sendable, so no process work blocks the main actor. A new immutable `AssistantRequest` keeps result identity, executable command, and arguments paired at the seam. Starting any request cancels and replaces the current run, including when both requests have identical values; query changes and Search Session resets cancel the run, while selection movement does not.

Assistant CLI availability discovery remains outside this module because it determines which keyword rows participate in Result Projection before any run exists. The existing `AssistantProcessRunning` seam remains the internal execution adapter, with production and scripted implementations.

## Consequences

Engine tests exercise the complete Assistant Run lifecycle through the production interface. Coordinator tests retain integration coverage for activation, query-driven cancellation, and rendering without reimplementing process lifecycle assertions; ADR 0005's performer tests cover clipboard representation. The module imports neither AppKit nor SwiftUI and stores no conversation history.
