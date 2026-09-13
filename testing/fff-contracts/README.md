# FFF contract tests

These tests materialize `fff-swift` 0.2.1 at revision `dbc38f5c81f44d0c7bac434f1f247ca01f1dfc9c`. They apply the tracked patch in `patches/` and never modify SwiftPM caches or the production dependency.

`make test-fff-contracts` runs R01 result and pagination properties, R02 C ownership checks, R03 lifecycle sequences, and the terminal protocol. The default pull-request lane runs 24 cases for each decimal seed below:

- `17361641481138401537`
- `17361641481138401538`
- `17361641481138401539`

Proptest prints the minimized operation list and persists its replay seed on failure. Keep both with a failure report.

`make test-fff-boundary` builds the C artifact from that source, binds it into an isolated Floodlight checkout, and runs `FFFIndexTests`. It then applies `known-mixed-search-fault.patch` and requires the focused Swift integration test to fail.

`make test-fff-mutations` runs cargo-mutants 27.1.0 against the two production pagination functions. Results under `.build/fff-mutations/results` separate caught, missed, timed-out, and unviable mutants. A missed mutant needs a behavior test or a written equivalence reason; a timeout remains unresolved.

`make test-swift-mutations` applies six reviewed fault patches individually to an isolated checkout. Each patch must apply cleanly and make its named transition test fail. The campaign covers stale publication, failed-scope recovery, failed-open learning, originating-query capture, independent opens, and the running-application fallback.

The portable Bombadil and Antithesis lanes live in `testing/fff-exploration`. Neither proves macOS FSEvents, Launch Services, AppKit activation, nor Antithesis cloud exploration.
