import FloodlightEngine
import FloodlightTestSupport
import Foundation
import XCTest

/// Differential and adversarial tests for `Calculator`.
///
/// The strategy: generate a random *expression tree* from exactly the
/// grammar the recursive-descent parser implements, render it to source
/// text (with random whitespace and redundant parentheses), and evaluate
/// the same tree with an independent reference interpreter. The two then
/// have to agree bit-for-bit — which catches precedence slips,
/// associativity slips, and the sign handling around `^` that a table of
/// hand-written examples never would.
///
/// The reference mirrors the parser's *documented* quirks rather than
/// school arithmetic: unary minus binds tighter than `^` (`-2^2 == 4`),
/// `^` is right-associative, and division or modulo by exactly zero fails
/// the whole expression instead of producing infinity.
final class CalculatorDifferentialTests: XCTestCase {

    // MARK: - The reference interpreter

    /// A node of the grammar the parser implements. Numbers carry their
    /// *rendered* text, so the reference evaluates the same `Double` the
    /// parser will produce from that text rather than one that merely
    /// rounds to the same place.
    private indirect enum Expression {
        case number(String)
        case negate(Expression)
        case unaryPlus(Expression)
        case grouped(Expression)
        case additive(Expression, [(Character, Expression)])
        case multiplicative(Expression, [(Character, Expression)])
        case power(Expression, Expression)
    }

    /// Evaluates a tree with the parser's exact semantics. `nil` means the
    /// parser is expected to reject the rendered source.
    private func evaluate(_ expression: Expression) -> Double? {
        switch expression {
        case .number(let text):
            return Double(text.replacingOccurrences(of: ",", with: ""))
        case .negate(let inner):
            return evaluate(inner).map { -$0 }
        case .unaryPlus(let inner):
            return evaluate(inner)
        case .grouped(let inner):
            return evaluate(inner)
        case .additive(let head, let rest):
            guard var value = evaluate(head) else { return nil }
            for (op, operand) in rest {
                guard let rhs = evaluate(operand) else { return nil }
                if op == "+" { value += rhs } else { value -= rhs }
            }
            return value
        case .multiplicative(let head, let rest):
            guard var value = evaluate(head) else { return nil }
            for (op, operand) in rest {
                guard let rhs = evaluate(operand) else { return nil }
                switch op {
                case "*":
                    value *= rhs
                case "/":
                    // The parser refuses before dividing, so a zero divisor
                    // fails the expression instead of yielding infinity.
                    guard rhs != 0 else { return nil }
                    value /= rhs
                default:
                    guard rhs != 0 else { return nil }
                    value.formTruncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        case .power(let base, let exponent):
            guard let baseValue = evaluate(base), let exponentValue = evaluate(exponent) else {
                return nil
            }
            return pow(baseValue, exponentValue)
        }
    }

    private func render(_ expression: Expression, gap: () -> String) -> String {
        switch expression {
        case .number(let text):
            return text
        case .negate(let inner):
            return "-\(gap())\(render(inner, gap: gap))"
        case .unaryPlus(let inner):
            return "+\(gap())\(render(inner, gap: gap))"
        case .grouped(let inner):
            return "(\(gap())\(render(inner, gap: gap))\(gap()))"
        case .additive(let head, let rest):
            return rest.reduce(render(head, gap: gap)) { text, step in
                "\(text)\(gap())\(step.0)\(gap())\(render(step.1, gap: gap))"
            }
        case .multiplicative(let head, let rest):
            return rest.reduce(render(head, gap: gap)) { text, step in
                "\(text)\(gap())\(step.0)\(gap())\(render(step.1, gap: gap))"
            }
        case .power(let base, let exponent):
            return "\(render(base, gap: gap))\(gap())^\(gap())\(render(exponent, gap: gap))"
        }
    }

    // MARK: - Generation

    /// Renders a number `parseNumber` can consume in full: digits with at
    /// most one decimal point, never scientific notation (an `e` would fail
    /// `looksLikeExpression` before the parser ever runs).
    private func makeNumberText(_ rng: inout SeededGenerator) -> String {
        switch Int.random(in: 0...9, using: &rng) {
        case 0:
            return "0"
        case 1:
            return "\(Int.random(in: 0...9, using: &rng))"
        case 2, 3:
            return String(
                format: "%.\(Int.random(in: 1...3, using: &rng))f",
                Double.random(in: 0...50, using: &rng)
            )
        case 4:
            // Leading zeroes are legal and must not change the value.
            return "00\(Int.random(in: 1...99, using: &rng))"
        default:
            return "\(Int.random(in: 1...9_999, using: &rng))"
        }
    }

    private func makeExpression(_ rng: inout SeededGenerator, depth: Int) -> Expression {
        guard depth > 0 else { return .number(makeNumberText(&rng)) }

        let terms = Int.random(in: 1...3, using: &rng)
        let head = makeTerm(&rng, depth: depth - 1)
        var rest: [(Character, Expression)] = []
        for _ in 1..<max(terms, 1) {
            let op: Character = Bool.random(using: &rng) ? "+" : "-"
            rest.append((op, makeTerm(&rng, depth: depth - 1)))
        }
        return rest.isEmpty ? head : .additive(head, rest)
    }

    private func makeTerm(_ rng: inout SeededGenerator, depth: Int) -> Expression {
        let factors = Int.random(in: 1...3, using: &rng)
        let head = makePower(&rng, depth: depth)
        var rest: [(Character, Expression)] = []
        for _ in 1..<max(factors, 1) {
            let operators: [Character] = ["*", "/", "%"]
            rest.append((operators[Int.random(in: 0...2, using: &rng)], makePower(&rng, depth: depth)))
        }
        return rest.isEmpty ? head : .multiplicative(head, rest)
    }

    private func makePower(_ rng: inout SeededGenerator, depth: Int) -> Expression {
        let base = makeUnary(&rng, depth: depth)
        // Exponents stay small: `pow` on a random pair overflows to
        // infinity almost immediately, and an expression that can only ever
        // be rejected tests nothing.
        guard depth > 0, Int.random(in: 0...5, using: &rng) == 0 else { return base }
        return .power(base, .number("\(Int.random(in: 0...3, using: &rng))"))
    }

    private func makeUnary(_ rng: inout SeededGenerator, depth: Int) -> Expression {
        switch Int.random(in: 0...9, using: &rng) {
        case 0:
            return .negate(makeUnary(&rng, depth: depth))
        case 1:
            return .unaryPlus(makeUnary(&rng, depth: depth))
        default:
            return makePrimary(&rng, depth: depth)
        }
    }

    private func makePrimary(_ rng: inout SeededGenerator, depth: Int) -> Expression {
        guard depth > 0, Int.random(in: 0...2, using: &rng) == 0 else {
            return .number(makeNumberText(&rng))
        }
        return .grouped(makeExpression(&rng, depth: depth - 1))
    }

    private func expressionGen(
        maxDepth: Int = 3,
        whitespace: Bool = true
    ) -> Gen<GeneratedExpression> {
        Gen(generate: { rng in
            let tree = self.makeExpression(&rng, depth: maxDepth)
            var localRNG = rng
            let gap: () -> String = {
                guard whitespace else { return "" }
                return String(repeating: " ", count: Int.random(in: 0...2, using: &localRNG))
            }
            var source = self.render(tree, gap: gap)
            rng = localRNG
            // `looksLikeExpression` demands at least one operator character,
            // so a tree that collapsed to a bare number would be rejected
            // for a reason that has nothing to do with arithmetic.
            if !source.contains(where: { "+-*/%^()".contains($0) }) {
                source = "(\(source))"
            }
            return GeneratedExpression(source: source, expected: self.evaluate(tree))
        })
    }

    private struct GeneratedExpression: CustomDebugStringConvertible {
        let source: String
        let expected: Double?

        var debugDescription: String {
            let outcome: String
            if let expected {
                outcome = String(expected)
            } else {
                outcome = "rejected"
            }
            return "\(String(reflecting: source)) → \(outcome)"
        }
    }

    // MARK: - Differential properties

    func testParserAgreesWithAReferenceInterpreterOnGeneratedExpressions() throws {
        try checkProperty(
            "Calculator.evaluate matches the reference interpreter",
            expressionGen(),
            runs: 2_000
        ) { sample in
            let actual = Calculator.evaluate(sample.source)
            guard let expected = sample.expected, expected.isFinite else {
                // A non-finite or failed reference means the parser's final
                // `value.isFinite` guard must reject it too.
                return actual == nil
            }
            guard let actual else { return false }
            return actual == expected || (actual.isNaN && expected.isNaN)
        }
    }

    func testWhitespaceBetweenTokensNeverChangesTheResult() throws {
        try checkProperty(
            "whitespace is insignificant between tokens",
            expressionGen(whitespace: false),
            runs: 800
        ) { sample in
            let spaced = sample.source.map { character -> String in
                "+-*/%^()".contains(character) ? " \(character) " : String(character)
            }.joined()
            return Calculator.evaluate(sample.source) == Calculator.evaluate(spaced)
        }
    }

    func testRedundantParenthesesNeverChangeTheResult() throws {
        try checkProperty(
            "wrapping a whole expression in parentheses is a no-op",
            expressionGen(),
            runs: 800
        ) { sample in
            Calculator.evaluate(sample.source) == Calculator.evaluate("(\(sample.source))")
        }
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        try checkProperty(
            "leading and trailing whitespace is trimmed before parsing",
            expressionGen(),
            runs: 500
        ) { sample in
            Calculator.evaluate(sample.source)
                == Calculator.evaluate("  \n \t\(sample.source)\t \n  ")
        }
    }

    func testEvaluationIsDeterministic() throws {
        try checkProperty(
            "evaluate is a pure function of its input",
            expressionGen(),
            runs: 500
        ) { sample in
            let first = Calculator.evaluate(sample.source)
            let second = Calculator.evaluate(sample.source)
            return first == second || (first?.isNaN == true && second?.isNaN == true)
        }
    }

    // MARK: - Precedence and associativity, pinned exactly

    func testUnaryMinusBindsTighterThanExponentiation() throws {
        // `-2 ^ 2` is 4, not -4: `parsePower` reads a full unary operand
        // before it looks for `^`. A deliberate divergence from most
        // calculators, so it gets pinned down rather than assumed.
        XCTAssertEqual(Calculator.evaluate("-2 ^ 2"), 4)
        XCTAssertEqual(Calculator.evaluate("0 - 2 ^ 2"), -4)

        try checkProperty(
            "-a ^ 2 == (-a) ^ 2",
            Gen<Int>.int(in: 1...20),
            runs: 200
        ) { value in
            Calculator.evaluate("-\(value) ^ 2") == Calculator.evaluate("(-\(value)) ^ 2")
        }
    }

    func testSubtractionIsLeftAssociative() throws {
        let operand = Gen<Int>.int(in: -999...999)
        try checkProperty(
            "a - b - c parses as (a - b) - c",
            operand,
            operand,
            operand,
            runs: 400
        ) { first, second, third in
            Calculator.evaluate("\(first) - \(second) - \(third)")
                == Calculator.evaluate("(\(first) - \(second)) - \(third)")
        }
    }

    func testDivisionIsLeftAssociative() throws {
        let operand = Gen<Int>.int(in: 1...999)
        try checkProperty(
            "a / b / c parses as (a / b) / c",
            operand,
            operand,
            operand,
            runs: 400
        ) { first, second, third in
            Calculator.evaluate("\(first) / \(second) / \(third)")
                == Calculator.evaluate("(\(first) / \(second)) / \(third)")
        }
    }

    func testExponentiationIsRightAssociative() throws {
        let operand = Gen<Int>.int(in: 1...3)
        try checkProperty(
            "a ^ b ^ c parses as a ^ (b ^ c)",
            operand,
            operand,
            operand,
            runs: 200
        ) { first, second, third in
            Calculator.evaluate("\(first) ^ \(second) ^ \(third)")
                == Calculator.evaluate("\(first) ^ (\(second) ^ \(third))")
        }
    }

    func testMultiplicationBindsTighterThanAddition() throws {
        let operand = Gen<Int>.int(in: -99...99)
        try checkProperty(
            "a + b * c parses as a + (b * c)",
            operand,
            operand,
            operand,
            runs: 400
        ) { first, second, third in
            Calculator.evaluate("\(first) + \(second) * \(third)")
                == Calculator.evaluate("\(first) + (\(second) * \(third))")
        }
    }

    func testModuloSharesPrecedenceWithMultiplication() throws {
        let operand = Gen<Int>.int(in: 1...99)
        try checkProperty(
            "a % b * c parses as (a % b) * c",
            operand,
            operand,
            operand,
            runs: 300
        ) { first, second, third in
            Calculator.evaluate("\(first) % \(second) * \(third)")
                == Calculator.evaluate("(\(first) % \(second)) * \(third)")
        }
    }

    func testGroupingCommasAreStrippedFromNumbers() throws {
        try checkProperty(
            "thousands separators do not change a number's value",
            Gen<Int>.int(in: 1_000...999_999),
            runs: 300
        ) { value in
            Calculator.evaluate("\(Self.grouped(value)) + 0")
                == Calculator.evaluate("\(value) + 0")
        }
    }

    /// Inserts ASCII commas every three digits — done by hand rather than
    /// through a `FormatStyle` so the fixture never depends on the test
    /// machine's locale.
    private static func grouped(_ value: Int) -> String {
        let digits = Array(String(abs(value)))
        var output: [Character] = []
        for (offset, digit) in digits.enumerated() {
            if offset > 0, (digits.count - offset).isMultiple(of: 3) {
                output.append(",")
            }
            output.append(digit)
        }
        return (value < 0 ? "-" : "") + String(output)
    }

    // MARK: - Rejection properties

    func testDivisionAndModuloByZeroAlwaysFailTheWholeExpression() throws {
        try checkProperty(
            "any zero divisor rejects the expression",
            Gen<Int>.int(in: -999...999),
            Gen<String>.element(of: ["/", "%"]),
            runs: 400
        ) { value, op in
            Calculator.evaluate("\(value) \(op) 0") == nil
                && Calculator.evaluate("1 + \(value) \(op) 0") == nil
                && Calculator.evaluate("(\(value) \(op) 0.0) + 1") == nil
                && Calculator.evaluate("\(value) \(op) -0") == nil
        }
    }

    func testUnbalancedParenthesesAreAlwaysRejected() throws {
        try checkProperty(
            "an unmatched parenthesis rejects the expression",
            expressionGen(maxDepth: 2),
            runs: 400
        ) { sample in
            Calculator.evaluate("(\(sample.source)") == nil
                && Calculator.evaluate("\(sample.source))") == nil
        }
    }

    func testTrailingOperatorsAreAlwaysRejected() throws {
        try checkProperty(
            "a dangling binary operator rejects the expression",
            expressionGen(maxDepth: 2),
            Gen<String>.element(of: ["+", "-", "*", "/", "%", "^"]),
            runs: 400
        ) { sample, op in
            Calculator.evaluate("\(sample.source) \(op)") == nil
        }
    }

    func testAnyOutOfAlphabetCharacterRejectsTheInput() throws {
        // `looksLikeExpression` allows only digits, whitespace, and
        // `.,+-*/%^()`. Everything else bails out before the parser runs —
        // this is what stops "yt lofi" from becoming a calculator row.
        // Note the absence of U+200B: Swift classifies the zero-width space
        // as whitespace, so it is *skipped*, not rejected. That surprise is
        // pinned down separately in
        // `testInvisibleWhitespaceIsSkippedRatherThanRejected`.
        let intruders = Gen<String>.element(of: [
            "a", "e", "E", "x", "π", "∞", "$", "€", "_", "!", "=", "&", "|", ":",
            ";", "#", "@", "?", "<", ">", "[", "]", "{", "}", "'", "\"", "\\",
            "😀",
        ])
        try checkProperty(
            "an out-of-alphabet character rejects the expression",
            expressionGen(maxDepth: 2),
            intruders
        ) { sample, intruder in
            Calculator.evaluate(sample.source + intruder) == nil
                && Calculator.evaluate(intruder + sample.source) == nil
        }
    }

    func testABareNonNegativeNumberIsNeverACalculatorResult() throws {
        // Without an operator character there is no expression — otherwise
        // typing a file named "2024" would surface a calculator row.
        try checkProperty(
            "a non-negative number with no operator is not an expression",
            Gen<Int>.int(in: 0...1_000_000)
        ) { value in
            Calculator.evaluate("\(value)") == nil
                && Calculator.evaluate("\(value).5") == nil
        }
    }

    func testALeadingSignTurnsABareNumberIntoAnExpression() throws {
        // The flip side of the rule above, and the reason it is stated for
        // *non-negative* numbers only: `-` and `+` are operator characters,
        // so `looksLikeExpression` accepts a signed literal and the unary
        // parser evaluates it. A file literally named "-1" would therefore
        // compete with a calculator row.
        try checkProperty(
            "a signed number is an expression",
            Gen<Int>.int(in: 1...1_000_000)
        ) { value in
            Calculator.evaluate("-\(value)") == Double(-value)
                && Calculator.evaluate("+\(value)") == Double(value)
        }
    }

    func testEveryCuratedRejectionCaseIsRejected() {
        for source in AdversarialCorpus.rejectedExpressions {
            XCTAssertNil(
                Calculator.evaluate(source),
                "expected \(String(reflecting: source)) to be rejected"
            )
        }
    }

    func testSurprisinglyAcceptedExpressionsKeepEvaluating() {
        for (source, expected) in AdversarialCorpus.surprisinglyAcceptedExpressions {
            XCTAssertEqual(
                Calculator.evaluate(source),
                expected,
                "expected \(String(reflecting: source)) to evaluate to \(expected)"
            )
        }
    }

    func testFoundationAndSwiftDisagreeAboutTheZeroWidthSpace() {
        // Two definitions of whitespace meet in `evaluate`, and they
        // disagree. `trimmingCharacters(in: .whitespacesAndNewlines)` uses
        // Foundation's `CharacterSet`, which still counts U+200B; the
        // `looksLikeExpression` scan uses Swift's `Character.isWhitespace`,
        // which does not. So a zero-width space is invisible at the edges
        // of a query and fatal in the middle of one.
        XCTAssertEqual(Calculator.evaluate("1 + 1\u{200B}"), 2)
        XCTAssertNil(Calculator.evaluate("1\u{200B}+\u{200B}1"))
        XCTAssertFalse(Character("\u{200B}").isWhitespace)
        XCTAssertTrue(CharacterSet.whitespacesAndNewlines.contains("\u{200B}"))

        for source in AdversarialCorpus.interiorInvisibleRejections {
            XCTAssertNil(
                Calculator.evaluate(source),
                "expected \(String(reflecting: source)) to be rejected"
            )
        }
    }

    func testUnicodeOperatorsAreNormalizedBeforeParsing() {
        XCTAssertEqual(Calculator.evaluate("6 × 7"), 42)
        XCTAssertEqual(Calculator.evaluate("84 ÷ 2"), 42)
        XCTAssertEqual(Calculator.evaluate("50 − 8"), 42)
        XCTAssertEqual(Calculator.evaluate("6 × 7 ÷ 2 − 1"), 20)
        // Only those three substitutions exist — a lookalike that isn't in
        // the table must still be rejected rather than silently coerced.
        XCTAssertNil(Calculator.evaluate("6 ∗ 7"))
        XCTAssertNil(Calculator.evaluate("6 ⨯ 7"))
        XCTAssertNil(Calculator.evaluate("50 – 8"))  // en dash, not minus sign
    }

    // MARK: - Non-finite results

    func testResultsThatOverflowToInfinityAreRejected() {
        XCTAssertNil(Calculator.evaluate("9\(String(repeating: "9", count: 400)) * 10"))
        XCTAssertNil(Calculator.evaluate("(10 ^ 308) * 10 ^ 10"))
        XCTAssertNil(Calculator.evaluate("0 ^ -1"))
        XCTAssertNil(Calculator.evaluate("(0 - 1) ^ 0.5"))
    }

    func testDeeplyNestedExpressionsDoNotOverflowTheStack() throws {
        // The parser is recursive descent with five frames per parenthesis
        // level, so nesting is the one input shape that can take the whole
        // process down. This runs on a thread with a generous stack and
        // asserts the parser still gets the right answer at a depth far
        // past anything a search field would receive.
        let depth = 5_000
        let source = String(repeating: "(", count: depth)
            + "1 + 1"
            + String(repeating: ")", count: depth)

        let outcome = try Self.runOnDedicatedStack(bytes: 64 << 20) {
            Calculator.evaluate(source)
        }
        XCTAssertEqual(outcome, 2)
    }

    func testDeeplyNestedUnaryOperatorsDoNotOverflowTheStack() throws {
        let depth = 5_000
        let source = String(repeating: "-", count: depth) + "7 + 0"
        let outcome = try Self.runOnDedicatedStack(bytes: 64 << 20) {
            Calculator.evaluate(source)
        }
        // An even number of negations cancels out.
        XCTAssertEqual(outcome, 7)
    }

    func testAVeryLongFlatExpressionStaysLinearAndCorrect() {
        // 20k terms, no nesting: this exercises the iterative loops rather
        // than the recursion, and must not take pathological time.
        let terms = 20_000
        let source = Array(repeating: "1", count: terms).joined(separator: "+")
        let start = ContinuousClock.now
        let value = Calculator.evaluate(source)
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(value, Double(terms))
        XCTAssertLessThan(elapsed, .seconds(2), "flat expression parsing should stay linear")
    }

    func testEveryAdversarialStringIsHandledWithoutCrashing() {
        // Total-function check: no input may trap, hang, or throw. The
        // result itself is unconstrained — only that one comes back.
        for source in AdversarialCorpus.strings + AdversarialCorpus.searchQueries {
            let value = Calculator.evaluate(source)
            if let value {
                XCTAssertTrue(
                    value.isFinite,
                    "evaluate returned a non-finite value for \(String(reflecting: source))"
                )
                XCTAssertFalse(Calculator.format(value).isEmpty)
            }
        }
    }

    /// Runs `work` on a thread with an explicit stack size, so a
    /// recursion-depth test measures the parser rather than whatever stack
    /// the test runner happened to hand us.
    private static func runOnDedicatedStack<Value>(
        bytes: Int,
        _ work: @escaping @Sendable () -> Value
    ) throws -> Value {
        let box = ResultBox<Value>()
        let thread = Thread { box.value = work() }
        thread.stackSize = bytes
        thread.start()

        let deadline = Date().addingTimeInterval(30)
        while !thread.isFinished, Date() < deadline {
            usleep(1_000)
        }
        guard let value = box.value else {
            throw TestError.scripted("the dedicated-stack thread did not finish in time")
        }
        return value
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value?

        var value: Value? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                storage = newValue
                lock.unlock()
            }
        }
    }
}
