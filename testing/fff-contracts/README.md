# FFF contract tests

These tests materialize `fff-swift` 0.2.1 at revision `dbc38f5c81f44d0c7bac434f1f247ca01f1dfc9c`. They apply the tracked patch in `patches/` and never modify SwiftPM caches or the production dependency.

`make test-fff-contracts` runs R01 result and pagination properties, R02 C ownership and error checks, R03 lifecycle sequences, the terminal protocol, parser regressions, and frecency persistence regressions. The default pull-request lane runs 24 cases for each decimal seed below:

- `17361641481138401537`
- `17361641481138401538`
- `17361641481138401539`

Proptest prints the minimized operation list and persists its replay seed on failure. Keep both with a failure report.

`make test-fff-boundary` builds the C artifact from that source, binds it into an isolated Floodlight checkout, and runs `FFFIndexTests`. It then applies `known-mixed-search-fault.patch` and requires the focused Swift integration test to fail.

`make test-fff-mutations` runs cargo-mutants 27.1.0 against pagination, eligibility, query parsing, frecency persistence, and the C result-envelope error path. Results under `.build/fff-mutations/results` separate caught, missed, timed-out, unviable, and excluded checks. A missed mutant needs a behavior test or a written equivalence reason; a timeout remains unresolved.
The verified campaign reported pagination 8/16 caught and 8 unviable, eligibility 5/6 caught and 1 unviable, query parser 15/17 caught and 2 unviable, frecency persistence 11/11 caught, and the C result envelope 1/1 caught. It reported zero missed and zero timed-out mutants.

`make test-swift-mutations` applies eight reviewed fault patches individually to an isolated checkout. Each patch must apply cleanly and make its named transition test fail. The campaign covers stale publication, failed-scope recovery, failed-open learning, originating-query capture, independent opens, the running-application fallback, the character-mask guard, and the application candidate budget.

All discovered production mutation scopes run with behavior tests. Unviable mutations remain reported separately by cargo-mutants; no semantic-equivalent survivor is excluded.

The C result-envelope mutation is Cargo-visible through `fff-c` unit tests. The separate C smoke contract still exercises the exported ABI entrypoints, null handles, ownership, and result cleanup.

The portable Bombadil and Antithesis lanes live in `testing/fff-exploration`. Neither proves macOS FSEvents, Launch Services, AppKit activation, nor Antithesis cloud exploration.
