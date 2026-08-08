# Corpus and query-set design

Type: grilling
Status: open
Blocked by: 01, 04

## Question

Two design choices for what the bench actually runs against:

1. **Corpus**: ticket 01 fixed the roots as three tiers — `~/devv` (fast tier, every run), `~/Documents`, whole-home (slow tier, occasional). Still open: live directories vs snapshot per tier (note: committable snapshots are off the table — ticket 01 ruled all bench data gitignored), and the run cadence for each tier.
2. **Query set**: real queries mined from history (per 04), hand-written scenarios covering known query shapes (fuzzy filename, path query, `~/` query, trailing-slash directory, content fallback), or a mix — and how many queries make results stable without making runs slow?

Resolve via /grilling once 01 and 04 are closed.
