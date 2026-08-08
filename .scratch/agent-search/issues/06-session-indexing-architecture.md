# Session indexing architecture

Type: grilling
Status: open
Blocked by: 01

## Question

Given the store inventory (ticket 01), decide how sessions get indexed and searched:

- **Engine**: extend FFF (it already does frecency-ranked content grep) vs a dedicated session index inside FloodlightEngine — and where the per-agent adapter seam sits.
- **What's indexed**: titles/metadata only, full user+assistant text, or tool outputs too (noise and secrets risk).
- **Incrementality**: FSEvents across nine store roots, tailing append-only JSONL, reading WAL-mode SQLite safely while the owning agent runs.
- **Budgets**: index build time, memory for an always-resident launcher, query latency alongside file/app search.
- **Secrets**: whether transcripts get redaction or exclusion rules at index time (graduates the fog item).

Resolve via /grilling and /domain-modeling; the answer is the indexing section of the spec.
