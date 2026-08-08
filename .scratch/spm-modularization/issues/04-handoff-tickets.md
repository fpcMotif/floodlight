# Publish the execution handoff

Type: task
Status: resolved
Blocked by: 03

## Question

Turn the approved draft into ready-for-agent execution issues on `fpcMotif/floodlight` (never upstream): one issue per extraction PR, in the leaf-first order the seam map fixed, `ready-for-agent` label, to-tickets shape — each self-contained (files to move, target stanza, expected promotion log, test moves, revert story). Record what was published (issue URLs) in the answer; the map closes when the issues are live.

## Comments

2026-08-06 — f invoked `/to-spec`: the full spec is now published on this tracker as [spec.md](../spec.md) with `Status: ready-for-agent`. Open question for f before this ticket resolves: do the two per-PR GitHub issues still get created on the fork (spec linked from each), or does the spec itself stand as the handoff (then this ticket resolves by pointing at it)?

## Answer

Published 2026-08-06 on f's explicit go — both, as it turned out: the spec on this tracker ([spec.md](../spec.md), `Status: ready-for-agent`) plus the two per-PR issues on the fork, `ready-for-agent` label, self-contained (the spec isn't on GitHub, so each issue carries its full context):

- [Evict non-search concerns from SearchCoordinator (modularization PR 1 of 2)](https://github.com/fpcMotif/floodlight/issues/11)
- [Carve FloodlightEngine into its own SPM target (modularization PR 2 of 2)](https://github.com/fpcMotif/floodlight/issues/12) — blocked by #11 (body convention; plain GitHub has no native blocking)

The map's destination is reached: nothing left to decide before execution.
