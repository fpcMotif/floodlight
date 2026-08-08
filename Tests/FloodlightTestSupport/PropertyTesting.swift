import Foundation

// A deterministic, reproducible property-based testing harness.
//
// Every run is driven by an explicit seed, so a failure is replayable from
// the message alone — no "it failed on CI once" cases. On failure the
// harness shrinks the counterexample toward the smallest input that still
// falsifies the property, then throws, which XCTest surfaces as the test's
// failure with the shrunk value attached.
//
// This lives in its own target rather than in either test target because
// both the engine's tests and the shell's tests need the same generators —
// duplicating a PRNG is exactly how two suites start disagreeing about
// what "the same random input" means.

// MARK: - Deterministic randomness

/// SplitMix64 — small, fast, and fully specified, so the same seed produces
/// the same stream on every machine and every Swift version. `SystemRandom`
/// would make counterexamples unreproducible, which defeats shrinking.
package struct SeededGenerator: RandomNumberGenerator {
    package private(set) var state: UInt64

    package init(seed: UInt64) {
        state = seed
    }

    package mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

// MARK: - Generators

/// A value generator paired with a shrinker.
///
/// `shrink` returns strictly "simpler" candidates — smaller magnitudes,
/// shorter collections — and must never cycle, or the shrink loop wouldn't
/// terminate. The harness enforces a budget anyway.
package struct Gen<Value: Sendable>: Sendable {
    package let generate: @Sendable (inout SeededGenerator) -> Value
    package let shrink: @Sendable (Value) -> [Value]

    package init(
        generate: @escaping @Sendable (inout SeededGenerator) -> Value,
        shrink: @escaping @Sendable (Value) -> [Value] = { _ in [] }
    ) {
        self.generate = generate
        self.shrink = shrink
    }

    package func map<Mapped>(_ transform: @escaping @Sendable (Value) -> Mapped) -> Gen<Mapped> {
        Gen<Mapped>(generate: { rng in transform(generate(&rng)) })
    }

    /// Maps while preserving shrinking by keeping the *source* value around,
    /// so shrunk sources map to shrunk outputs.
    package func mapShrinking<Mapped>(
        _ transform: @escaping @Sendable (Value) -> Mapped
    ) -> Gen<(source: Value, value: Mapped)> {
        Gen<(source: Value, value: Mapped)>(
            generate: { rng in
                let source = generate(&rng)
                return (source, transform(source))
            },
            shrink: { pair in
                shrink(pair.source).map { ($0, transform($0)) }
            }
        )
    }

    package func filter(
        _ isIncluded: @escaping @Sendable (Value) -> Bool,
        attempts: Int = 200
    ) -> Gen<Value> {
        Gen(
            generate: { rng in
                var candidate = generate(&rng)
                var remaining = attempts
                while !isIncluded(candidate), remaining > 0 {
                    candidate = generate(&rng)
                    remaining -= 1
                }
                return candidate
            },
            shrink: { value in shrink(value).filter(isIncluded) }
        )
    }
}

package extension Gen where Value == Int {
    /// Integers shrunk toward zero (or toward the end of `range` nearest
    /// zero, when zero itself is out of range).
    static func int(in range: ClosedRange<Int>) -> Gen<Int> {
        Gen(
            generate: { rng in Int.random(in: range, using: &rng) },
            shrink: { value in
                let target = range.contains(0) ? 0 : (abs(range.lowerBound) < abs(range.upperBound)
                    ? range.lowerBound
                    : range.upperBound)
                guard value != target else { return [] }
                var candidates = [target]
                let midpoint = target + (value - target) / 2
                if midpoint != value, midpoint != target, range.contains(midpoint) {
                    candidates.append(midpoint)
                }
                let step = value > target ? value - 1 : value + 1
                if step != target, range.contains(step) {
                    candidates.append(step)
                }
                return candidates
            }
        )
    }
}

package extension Gen where Value == Double {
    static func double(in range: ClosedRange<Double>) -> Gen<Double> {
        Gen(
            generate: { rng in Double.random(in: range, using: &rng) },
            shrink: { value in
                guard value != 0, range.contains(0) else { return [] }
                return [0, value.rounded(.towardZero), value / 2].filter {
                    $0 != value && range.contains($0)
                }
            }
        )
    }
}

package extension Gen where Value == Bool {
    static let bool = Gen<Bool>(
        generate: { rng in Bool.random(using: &rng) },
        shrink: { $0 ? [false] : [] }
    )
}

package extension Gen {
    static func always(_ value: Value) -> Gen<Value> {
        Gen(generate: { _ in value })
    }

    /// Picks uniformly from `values`, shrinking toward the first element —
    /// so a failing case reported against the last element gets retried
    /// against every earlier one.
    static func element(of values: [Value]) -> Gen<Value> {
        precondition(!values.isEmpty, "Gen.element requires a non-empty array")
        return Gen(
            generate: { rng in values[Int.random(in: 0..<values.count, using: &rng)] },
            shrink: { value in
                guard
                    let index = values.firstIndex(where: { candidate in
                        String(describing: candidate) == String(describing: value)
                    }),
                    index > 0
                else {
                    return []
                }
                return Array(values[0..<index].reversed())
            }
        )
    }

    /// Weighted choice between generators — the weights let a corpus of
    /// nasty inputs stay a minority of a stream that's mostly ordinary, so
    /// a property still gets exercised on realistic values.
    static func frequency(_ choices: [(weight: Int, gen: Gen<Value>)]) -> Gen<Value> {
        precondition(!choices.isEmpty, "Gen.frequency requires at least one choice")
        let total = choices.reduce(0) { $0 + max(0, $1.weight) }
        precondition(total > 0, "Gen.frequency requires a positive total weight")
        return Gen(
            generate: { rng in
                var roll = Int.random(in: 0..<total, using: &rng)
                for choice in choices {
                    roll -= max(0, choice.weight)
                    if roll < 0 {
                        return choice.gen.generate(&rng)
                    }
                }
                return choices[choices.count - 1].gen.generate(&rng)
            },
            shrink: { value in choices[0].gen.shrink(value) }
        )
    }

    static func array(
        of element: Gen<Value>,
        count: ClosedRange<Int>
    ) -> Gen<[Value]> {
        Gen<[Value]>(
            generate: { rng in
                let size = Int.random(in: count, using: &rng)
                return (0..<size).map { _ in element.generate(&rng) }
            },
            shrink: { values in
                guard values.count > count.lowerBound else { return [] }
                var candidates: [[Value]] = []
                let half = values.count / 2
                if half >= count.lowerBound, half < values.count {
                    candidates.append(Array(values.prefix(half)))
                    candidates.append(Array(values.suffix(half)))
                }
                if values.count - 1 >= count.lowerBound {
                    for index in values.indices {
                        var reduced = values
                        reduced.remove(at: index)
                        candidates.append(reduced)
                        if candidates.count > 12 { break }
                    }
                }
                return candidates
            }
        )
    }
}

package extension Gen where Value == String {
    /// Strings drawn from an explicit alphabet, shrunk by deleting
    /// characters — the shape that makes a fuzzy-matching counterexample
    /// readable instead of a wall of noise.
    static func string(
        alphabet: [Character],
        length: ClosedRange<Int>
    ) -> Gen<String> {
        precondition(!alphabet.isEmpty, "Gen.string requires a non-empty alphabet")
        return Gen(
            generate: { rng in
                let size = Int.random(in: length, using: &rng)
                return String((0..<size).map { _ in
                    alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]
                })
            },
            shrink: { value in
                let characters = Array(value)
                guard characters.count > length.lowerBound else { return [] }
                var candidates: [String] = []
                let half = characters.count / 2
                if half >= length.lowerBound, half < characters.count {
                    candidates.append(String(characters.prefix(half)))
                    candidates.append(String(characters.suffix(half)))
                }
                for index in characters.indices {
                    var reduced = characters
                    reduced.remove(at: index)
                    if reduced.count >= length.lowerBound {
                        candidates.append(String(reduced))
                    }
                    if candidates.count > 12 { break }
                }
                return candidates
            }
        )
    }

    static let lowercaseASCII = Gen<String>.string(
        alphabet: Array("abcdefghijklmnopqrstuvwxyz"),
        length: 0...12
    )

    /// ASCII with the separators the fuzzy matcher treats as word
    /// boundaries, so boundary-bonus paths actually get hit.
    static let asciiWithSeparators = Gen<String>.string(
        alphabet: Array("abcdefghijklmnopqrstuvwxyz0123456789 -_/."),
        length: 0...24
    )

    /// Mostly ordinary text, seasoned with the inputs that break naive
    /// string handling: combining marks, emoji sequences, bidi overrides,
    /// zero-width joiners, and CJK.
    static let hostile = Gen<String>.frequency([
        (
            6,
            .string(
                alphabet: Array("abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
                length: 0...20
            )
        ),
        (3, .string(alphabet: Array("éüñçåøßÆΩ日本語テスト한국어Кириллица"), length: 0...12)),
        (
            2,
            .string(
                alphabet: Array("\u{200B}\u{200D}\u{FEFF}\u{202E}\u{0301}\u{0328}\u{00A0}\u{2028}"),
                length: 0...8
            )
        ),
        (2, .string(alphabet: Array("👨‍👩‍👧‍👦🇦🇶🏳️‍🌈👋🏽🧑‍🚀"), length: 0...5)),
        (3, .string(alphabet: Array("\\\"'`$&|;<>(){}[]*?!#%~^"), length: 0...10)),
        (1, .element(of: AdversarialCorpus.strings)),
    ])
}

// MARK: - Running properties

package struct PropertyFailure: LocalizedError, CustomStringConvertible {
    package let property: String
    package let counterexample: String
    package let shrinkSteps: Int
    package let run: Int
    package let seed: UInt64
    package let location: String

    package var description: String {
        """
        Property failed: \(property)
          counterexample: \(counterexample)
          found on run \(run) of seed 0x\(String(seed, radix: 16, uppercase: true)), \
        shrunk \(shrinkSteps) time(s)
          declared at \(location)
          replay: rerun with seed 0x\(String(seed, radix: 16, uppercase: true))
        """
    }

    package var errorDescription: String? {
        description
    }
}

/// The default number of cases each property runs.
///
/// High enough that a one-in-a-hundred edge case shows up reliably, low
/// enough that a suite of ~40 properties still finishes in seconds.
package let defaultPropertyRuns = 400

/// Runs `property` against generated values, shrinking any counterexample
/// before throwing. Throwing (rather than calling `XCTFail`) keeps this
/// target free of an XCTest dependency and still fails the calling test,
/// with the shrunk counterexample in the message.
package func checkProperty<Value>(
    _ description: String,
    _ generator: Gen<Value>,
    runs: Int = defaultPropertyRuns,
    seed: UInt64 = 0xF100_D116_4700_0001,
    shrinkBudget: Int = 400,
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (Value) throws -> Bool
) throws {
    var rng = SeededGenerator(seed: seed)
    for run in 0..<runs {
        let value = generator.generate(&rng)
        if try property(value) { continue }

        var smallest = value
        var steps = 0
        var budget = shrinkBudget
        shrinking: while budget > 0 {
            for candidate in generator.shrink(smallest) {
                budget -= 1
                if budget <= 0 { break shrinking }
                if try !property(candidate) {
                    smallest = candidate
                    steps += 1
                    continue shrinking
                }
            }
            break
        }

        throw PropertyFailure(
            property: description,
            counterexample: String(reflecting: smallest),
            shrinkSteps: steps,
            run: run,
            seed: seed,
            location: "\(file):\(line)"
        )
    }
}

/// The two-input form. Swift can't infer a tuple generator cleanly enough
/// to make `checkProperty` read well for binary properties, and binary
/// properties (query × candidate, item × filter) are most of what this
/// codebase needs.
package func checkProperty<A, B>(
    _ description: String,
    _ first: Gen<A>,
    _ second: Gen<B>,
    runs: Int = defaultPropertyRuns,
    seed: UInt64 = 0xF100_D116_4700_0002,
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (A, B) throws -> Bool
) throws {
    let paired = Gen<(A, B)>(
        generate: { rng in (first.generate(&rng), second.generate(&rng)) },
        shrink: { pair in
            first.shrink(pair.0).map { ($0, pair.1) }
                + second.shrink(pair.1).map { (pair.0, $0) }
        }
    )
    try checkProperty(
        description,
        paired,
        runs: runs,
        seed: seed,
        file: file,
        line: line
    ) { try property($0.0, $0.1) }
}

/// The three-input form, for the associativity and distributivity shapes
/// that need a third operand.
package func checkProperty<A, B, C>(
    _ description: String,
    _ first: Gen<A>,
    _ second: Gen<B>,
    _ third: Gen<C>,
    runs: Int = defaultPropertyRuns,
    seed: UInt64 = 0xF100_D116_4700_0003,
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (A, B, C) throws -> Bool
) throws {
    let tripled = Gen<(A, B, C)>(
        generate: { rng in
            (first.generate(&rng), second.generate(&rng), third.generate(&rng))
        },
        shrink: { triple in
            first.shrink(triple.0).map { ($0, triple.1, triple.2) }
                + second.shrink(triple.1).map { (triple.0, $0, triple.2) }
                + third.shrink(triple.2).map { (triple.0, triple.1, $0) }
        }
    )
    try checkProperty(
        description,
        tripled,
        runs: runs,
        seed: seed,
        file: file,
        line: line
    ) { try property($0.0, $0.1, $0.2) }
}

// MARK: - Concurrency stress

/// Runs `body` from `concurrency` threads, `iterations` times each, and
/// returns only once every thread is done.
///
/// Used to hammer the lock-guarded types (`RecentStore`,
/// `CatalogRefreshGuard`, the catalogs' snapshot accessors) hard enough
/// that a missing lock shows up as a crash or a torn read under TSan,
/// rather than as a rare production heisenbug.
package func hammerConcurrently(
    concurrency: Int = 16,
    iterations: Int = 200,
    _ body: @escaping @Sendable (_ thread: Int, _ iteration: Int) -> Void
) {
    DispatchQueue.concurrentPerform(iterations: concurrency) { thread in
        for iteration in 0..<iterations {
            body(thread, iteration)
        }
    }
}

/// A counter safe to bump from any thread, for asserting on how many
/// racing callers observed a given outcome.
package final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    package init(_ initial: Int = 0) {
        storage = initial
    }

    @discardableResult
    package func increment(by amount: Int = 1) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += amount
        return storage
    }

    package var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// A thread-safe bag for values collected across racing callers.
package final class ConcurrentBag<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    package init() {}

    package func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }

    package var values: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
