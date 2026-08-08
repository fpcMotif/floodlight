# Spotlight baseline runner: driving mdfind fairly

## Summary

`mdfind` is scriptable enough to be the Spotlight baseline for **latency and recall**: `-name` for filename queries, raw `kMDItem*` predicates or `-interpret` for content queries, `-onlyin` for root scoping, `-count` for cheap recall checks. It is **not usable for ranking comparison**: the CLI emits an unordered result set with no relevance scores. Relevance is only reachable via the APIs (`NSMetadataQuery` sort descriptors + `NSMetadataQueryResultContentRelevanceAttribute` / CoreServices `kMDQueryResultContentRelevance`), it is only computed for content searches, and even then it is a per-item score, not the ranking Spotlight's UI shows. So the benchmark should score Spotlight on latency + recall, and treat ranking as FFF/Floodlight vs. fd|fzf only (or build a small NSMetadataQuery harness if ranking parity is required). Biggest fairness trap, observed live on this machine: **Spotlight indexing can simply be off** (`mdutil -sa` here reports "Indexing disabled." on every volume, and mdfind returned 0 hits for files fd proves exist). The runner must assert index health before timing anything.

---

## 1. Driving mdfind programmatically

All flags below from `man mdfind` (mdfind(1), read on this Mac via `man mdfind | col -b`):

| Flag | Man-page text | Benchmark use |
|---|---|---|
| `-name fileName` | "Searches for matching file names only." | Filename-only queries |
| `-onlyin dir` | "Limit the scope of the search to the directory specified." | Scope to benchmark corpus root |
| `-count` | "output the total number of matches, instead of the path" | Recall measurement without stdout-volume noise |
| `-live` | "provide live-updates to the number of files matching the query" | Not for batch benchmarking (never exits); only relevant if benchmarking incremental/watch mode |
| `-literal` | "Force the provided query string to be taken as a literal query string, without interpretation." | Use with raw predicates to avoid the natural-language parser |
| `-interpret` | "interpreted as if the user had typed the string into the Spotlight menu" | Closest emulation of what a Spotlight user experiences |
| `-0` | NUL-separated output | Safe piping to `xargs -0` / result-diffing |

The `-interpret` docs give the exact expansion Spotlight's UI applies — for input "search" it produces (mdfind(1)):

```
(* = search* cdw || kMDItemTextContent = search* cdw)
```

i.e. word-prefix match (`w` = word-boundary, `c` = case-insensitive, `d` = diacritic-insensitive) across all attributes OR text content. This is the canonical "content query" for the baseline.

### Predicate syntax for Floodlight's query shapes

Syntax per Apple's File Metadata Query Expression Syntax (developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryFormat.html): comparisons `== != < > <= >=`, modifiers in trailing position (`c` case-insensitive, `d` diacritic-insensitive), wildcards `*` (multi-char) and `?` (single char), combinators `&&` / `||`, e.g. `kMDItemTextContent == "*paris*"` for substring, `"paris*"` for prefix.

Relevant attributes confirmed in the local schema (`mdimport -A`, 289 attributes; mdimport(1): `-A` "Print out the list of all of the attributes"):

- `kMDItemFSName` — "Name of the file" (keyword: `filename`)
- `kMDItemDisplayName` — "Localized name of the file" (keywords: `name, displayname`)
- `kMDItemTextContent` — "Text content of this item" (keywords: `content, contains, intext`)
- `kMDItemPath` — "Complete pathname of this file" (keyword: `path`) — listed in the schema, but path-substring predicates against it are not a supported search pattern; see caveat below.

Query-shape mapping:

| Floodlight query shape | Fair mdfind equivalent | Caveat |
|---|---|---|
| Fuzzy filename (`flght` → `floodlight`) | **None.** Closest: `mdfind -onlyin ROOT -name flght` or `kMDItemFSName == "*flght*"cd` | Spotlight has only exact/wildcard/word-prefix matching (QueryFormat doc lists no fuzzy operator). Benchmark must either (a) feed Spotlight the un-fuzzed literal term and score it on that easier query, or (b) feed the fuzzy pattern and accept recall = 0. Report which convention is used; (a) is the defensible one. |
| Substring filename | `mdfind -onlyin ROOT "kMDItemFSName == '*PAT*'cd"` | Word-boundary behavior differs from a byte-substring scan; `-name` matching is name-only per mdfind(1). |
| Path-ish query (`src/main`) | `mdfind -onlyin ROOT/src -name main` — decompose into `-onlyin` scope + leaf name | Spotlight's query language matches indexed attributes, not path substrings; `-onlyin` is the only path lever mdfind(1) documents. Untestable on this machine (index disabled), so treat any `kMDItemPath ==` predicate as unverified. |
| Content search | `mdfind -onlyin ROOT "kMDItemTextContent == 'term*'cdw"` or `mdfind -onlyin ROOT -interpret term` | `-interpret` also matches `* = term*` (any attribute), so it over-matches vs. pure content; pick one form and keep it fixed. |

## 2. Ranking comparability: latency/recall only, not relevance (via CLI)

- mdfind(1) says only that it "returns a list of files that match the given metadata query" — **no ordering or relevance is documented or exposed** by the CLI. Treat its output as an unordered set.
- Relevance exists in the APIs only:
  - CoreServices `kMDQueryResultContentRelevance`: "A CFNumberRef with a floating point value between 0.0 and 1.0 inclusive." (developer.apple.com/documentation/coreservices/kmdqueryresultcontentrelevance)
  - Foundation `NSMetadataQueryResultContentRelevanceAttribute`: "floating point value between 0.0 and 1.0 … indicates the relevance of the content of a result object … computed based on the value of the result itself, not on its relevance to the other results returned by the query. If the value is not computed, it is treated as an attribute … that does not exist." (developer.apple.com/documentation/foundation/nsmetadataqueryresultcontentrelevanceattribute)
  - Ordering requires `NSMetadataQuery.sortDescriptors` ("An array of sort descriptor objects", developer.apple.com/documentation/foundation/nsmetadataquery/sortdescriptors) — e.g. sort by the relevance attribute.
- Consequences for the benchmark:
  1. With `mdfind` alone, Spotlight competes on **latency and recall only**. Any nDCG/MRR-style ranking metric must exclude it or use rank-agnostic scoring (set overlap).
  2. If ranking parity is required, it needs a small Swift/ObjC harness around `NSMetadataQuery` sorting on `NSMetadataQueryResultContentRelevanceAttribute` — and even that covers content queries only ("relevance of the content"; per the docs the value may simply not be computed, e.g. for name-only matches).
  3. Spotlight-UI "Top Hit" ordering incorporates signals not exposed by either API, so no harness reproduces what users see in the Spotlight window; state this limitation in the benchmark write-up.

## 3. Fairness caveats and mitigations

### Index state (observed failure mode on this machine)

- `mdutil -s` "Display the indexing status of the listed volumes"; `-a` all volumes; `-i on|off` toggles indexing; `-E` erases and rebuilds the store (mdutil(1)).
- **Observed here (2026-08-05):** `mdutil -sa` → "Indexing disabled." for `/`, `/System/Volumes/Data`, `/System/Volumes/Preboot`, `/Volumes/Floodlight`; consequently `mdfind -count -onlyin ~/devv -name Package.swift` → `0` while `fd -H -g 'Package.swift' ~/devv` finds **2**. A naive runner would score Spotlight at 0% recall and ~60 ms latency and be wrong on both counts.
- **Mitigation:** the runner must pre-flight `mdutil -s <volume-of-corpus>` and abort unless it reports "Indexing enabled."; record the mdutil output in the run manifest.

### Index staleness after corpus churn

- Spotlight indexes asynchronously; files created/modified by benchmark setup are not instantly queryable. mdutil(1) even warns "indexing may be delayed due to low disk space or other conditions."
- **Mitigation:** after building the corpus, force import with `mdimport -i <corpusdir>` ("Request Spotlight to import file or recursively import directory … attributes will be stored in the Spotlight index", mdimport(1)), then poll `mdfind -count -onlyin <corpusdir> <sentinel-query>` until the expected count is reached before starting timers.

### Default exclusions (recall asymmetry)

- Users/admins can exclude any folder or volume via System Settings → Spotlight → Search Privacy ("Exclude files in a folder or disk from Spotlight searches: Click the Add button, then select a folder or disk." — support.apple.com/guide/mac-help/prevent-spotlight-searches-mchl1bb43b84/mac). The runner cannot read this list programmatically; document that the corpus root must not be in it.
- Hidden files/dot-directories and much of `~/Library` are not surfaced by normal Spotlight queries, and directories can be opted out via a `.noindex` name suffix or `.metadata_never_index` marker (widely documented convention; not in the man pages — flagged as secondary-source). Meanwhile FFF/fd (with `-H -I`) see everything.
- **Mitigation:** place the corpus in a plain visible directory (not under `~/Library`, no dotfile roots), or restrict every engine to the same visible-file subset and compute recall against that subset.

### Latency-measurement pitfalls

- **First-run effects:** each mdfind invocation logs `[UserQueryParser] Loading keywords and predicates for locale "en_US"` (observed), and the first query after boot/idle pays mds XPC wake-up and cold caches. Discard first runs.
- **Process-spawn overhead:** mdfind, fd, and fzf runs each pay fork/exec (~ms scale), which dominates sub-10 ms searches. Either accept it uniformly for all CLI baselines (including Floodlight's CLI) or benchmark Floodlight in-process and label the comparison accordingly.
- **Mitigation — hyperfine** (installed, v1.20.0): `-w/--warmup NUM` "Perform NUM warmup runs before the actual benchmark. This can be used to fill (disk) caches for I/O-heavy programs"; `-r/--runs NUM` for fixed iteration counts (hyperfine --help). Example: `hyperfine -w 3 -r 20 "mdfind -onlyin $ROOT -name $PAT" "fd -H -I $PAT $ROOT"`.
- Report cold and warm numbers separately (cold: after `mdutil -E` rebuild settles / first query after purge; warm: post-warmup steady state).

## 4. Secondary baselines: fd and fzf — yes, include them

Both installed: `fd 10.4.2`, `fzf 0.74.1` (`which fd fzf`). They are the natural non-indexed filename baselines: fd measures pure walk latency, fd|fzf adds fuzzy matching + score ranking, which mdfind cannot do at all — making them the **only ranking-capable baseline** for the fuzzy-filename shape.

Fair invocations:

- Walk parity: `fd --hidden --no-ignore <pat> <root>` — by default fd skips hidden files and respects ignore files (`-H, --hidden`: "default: hidden files and directories are skipped"; `-I, --no-ignore` disables ignore-file filtering — fd --help). Choose flags to match whatever visibility rules Floodlight itself uses, and keep them fixed.
- Fuzzy + ranked: `fd . <root> | fzf --filter '<query>'` — `-f, --filter=STR` is "Filter mode. Do not start interactive finder" (fzf(1)); output is match-score-sorted by default (fzf(1) notes it becomes "a fuzzy-version of grep" only when you add `--no-sort`). fzf even ships a built-in latency tool: `--bench=DURATION` "Repeatedly run --filter for the given duration and print timing statistics" (fzf(1)).
- Cache caveat: fd's latency is dominated by the kernel dirent/inode cache — observed cold-ish walk of `~/devv` at 0.218 s vs. 0.014 s for fd|fzf over the already-hot floodlight tree. Warm-up runs are mandatory before comparing against index-backed engines.

## 5. Recommended runner shape

1. Pre-flight: `mdutil -s $VOL` must say "Indexing enabled."; `mdimport -i $CORPUS`; poll `mdfind -count` sentinel until stable.
2. Per query shape, fixed command templates: `mdfind -onlyin $ROOT -name $PAT` / `mdfind -onlyin $ROOT -literal "$PREDICATE"` / `mdfind -onlyin $ROOT -interpret $TERM`; `fd -H -I $PAT $ROOT`; `fd . $ROOT | fzf --filter "$QUERY"`; Floodlight CLI equivalent.
3. Time with `hyperfine -w 3 -r 20`; capture result sets separately (untimed, `-0`) for recall/overlap scoring.
4. Score Spotlight on latency + recall only; score ranking metrics for engines that emit ordered results (Floodlight, fd|fzf). Note the NSMetadataQuery relevance harness as optional future work.

## Sources

- mdfind(1), mdutil(1), mdls(1), mdimport(1) — read on this Mac, 2026-08-05 (`man X | col -b`).
- File Metadata Query Expression Syntax — https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryFormat.html
- NSMetadataQuery.sortDescriptors — https://developer.apple.com/documentation/foundation/nsmetadataquery/sortdescriptors
- NSMetadataQueryResultContentRelevanceAttribute — https://developer.apple.com/documentation/foundation/nsmetadataqueryresultcontentrelevanceattribute
- kMDQueryResultContentRelevance — https://developer.apple.com/documentation/coreservices/kmdqueryresultcontentrelevance
- Spotlight Search Privacy — https://support.apple.com/guide/mac-help/prevent-spotlight-searches-mchl1bb43b84/mac
- fd --help (10.4.2), fzf(1) (0.74.1), hyperfine --help (1.20.0) — local.
- Observed command output on this machine, 2026-08-05: `mdutil -sa`, `mdfind -count -onlyin ~/devv -name Package.swift` (0 hits, ~0.058 s), `fd -H -g 'Package.swift' ~/devv` (2 hits, 0.218 s), `fd . ~/devv/floodlight | fzf --filter 'pckg swift'` (0.014 s).
