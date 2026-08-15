import FloodlightTestSupport
import Foundation
import XCTest
@testable import FloodlightEngine

/// Adversarial, property-based, and stress tests for `Calculator` —
/// algebraic laws over seeded random inputs, parser fuzzing over hostile
/// strings, pathological nesting, and exact documentation of the parser's
/// surprising-but-deliberate behaviors.
final class CalculatorAdversarialTests: XCTestCase {
    // MARK: - Algebraic laws (seeded properties)

    func testAdditionIsCommutative() throws {
        try checkProperty(
            "addition is commutative",
            .double(in: -10_000...10_000), .double(in: -10_000...10_000)
        ) { leftOperand, rightOperand in
            evalEqual(
                formatExpression(leftOperand, "+", rightOperand),
                formatExpression(rightOperand, "+", leftOperand),
                accuracy: 1e-6
            )
        }
    }

    func testMultiplicationIsCommutative() throws {
        try checkProperty(
            "multiplication is commutative",
            .double(in: -10_000...10_000), .double(in: -10_000...10_000)
        ) { leftOperand, rightOperand in
            evalEqual(
                formatExpression(leftOperand, "*", rightOperand),
                formatExpression(rightOperand, "*", leftOperand),
                accuracy: 1e-6
            )
        }
    }

    func testAdditionIsAssociative() throws {
        try checkProperty(
            "addition is associative",
            .double(in: -1_000...1_000), .double(in: -1_000...1_000)
        ) { firstValue, secondValue in
            let thirdValue = firstValue / 2
            return evalEqual(
                "(\(num(firstValue)) + \(num(secondValue))) + \(num(thirdValue))",
                "\(num(firstValue)) + (\(num(secondValue)) + \(num(thirdValue)))",
                accuracy: 0.01
            )
        }
    }

    func testMultiplicationDistributesOverAddition() throws {
        try checkProperty(
            "multiplication distributes over addition",
            .double(in: -100...100), .double(in: -100...100)
        ) { multiplier, firstAddend in
            let secondAddend = firstAddend / 3
            return evalEqual(
                "\(num(multiplier)) * (\(num(firstAddend)) + \(num(secondAddend)))",
                "\(num(multiplier)) * \(num(firstAddend)) + \(num(multiplier)) * \(num(secondAddend))",
                accuracy: 0.01
            )
        }
    }

    func testAdditiveAndMultiplicativeIdentities() throws {
        try checkProperty("identities hold", .double(in: -10_000...10_000)) { value in
            evalEqual("\(num(value)) + 0", value, accuracy: 1e-9)
                && evalEqual("\(num(value)) * 1", value, accuracy: 1e-9)
                && evalEqual("\(num(value)) * 0", 0, accuracy: 1e-9)
        }
    }

    func testDoubleNegationIsIdentity() throws {
        try checkProperty("--a == a", .double(in: -10_000...10_000)) { value in
            evalEqual("--\(num(value))", value, accuracy: 1e-9)
        }
    }

    func testSelfSubtractionAndSelfDivision() throws {
        try checkProperty(
            "a - a == 0 and a / a == 1",
            .double(in: 0.5...10_000)
        ) { value in
            evalEqual("\(num(value)) - \(num(value))", 0, accuracy: 1e-9)
                && evalEqual("\(num(value)) / \(num(value))", 1, accuracy: 1e-9)
        }
    }

    func testPowerProperties() throws {
        try checkProperty("a^1 == a, a^0 == 1", .double(in: 0.5...100)) { base in
            evalEqual("\(num(base)) ^ 1", base, accuracy: 1e-9)
                && evalEqual("\(num(base)) ^ 0", 1, accuracy: 1e-9)
                && evalEqual("\(num(base)) ^ 2", base * base, accuracy: 0.01)
        }
    }

    func testPrecedenceAndLeftAssociativity() throws {
        try checkProperty(
            "precedence and left associativity",
            .double(in: 1...100), .double(in: 1...100)
        ) { firstValue, secondValue in
            let thirdValue = secondValue / 2
            return evalEqual(
                "\(num(firstValue)) + \(num(secondValue)) * \(num(thirdValue))",
                firstValue + secondValue * thirdValue,
                accuracy: 0.01
            )
                && evalEqual(
                    "\(num(firstValue)) - \(num(secondValue)) - \(num(thirdValue))",
                    firstValue - secondValue - thirdValue,
                    accuracy: 0.01
                )
                && evalEqual(
                    "\(num(firstValue)) / \(num(secondValue)) / \(num(thirdValue))",
                    firstValue / secondValue / thirdValue,
                    accuracy: 0.01
                )
        }
    }

    func testModuloOfMultipleIsZero() throws {
        try checkProperty(
            "(n*k) % k == 0 for integers",
            .int(in: 1...100), .int(in: 2...20)
        ) { multiplier, divisor in
            evalEqual("\(multiplier * divisor) % \(divisor)", 0, accuracy: 1e-9)
        }
    }

    func testWhitespaceAndUnicodeOperatorInvariance() throws {
        try checkProperty(
            "whitespace and unicode operators do not change results",
            .double(in: -100...100), .double(in: 0.5...100)
        ) { leftOperand, rightOperand in
            evalEqual(
                "\(num(leftOperand))+\(num(rightOperand))",
                "\(num(leftOperand))  +  \(num(rightOperand))",
                accuracy: 1e-9
            )
                && evalEqual(
                    "\(num(leftOperand)) × \(num(rightOperand))",
                    "\(num(leftOperand)) * \(num(rightOperand))",
                    accuracy: 1e-9
                )
                && evalEqual(
                    "\(num(leftOperand)) ÷ \(num(rightOperand))",
                    "\(num(leftOperand)) / \(num(rightOperand))",
                    accuracy: 1e-9
                )
                && evalEqual("−\(num(leftOperand))", "-\(num(leftOperand))", accuracy: 1e-9)
        }
    }

    // MARK: - Parser fuzzing (hostile inputs never crash, never produce non-finite)

    func testHostileStringsNeverCrashAndNeverYieldNonFinite() throws {
        try checkProperty("hostile input stays safe", Gen<String>.hostile) { input in
            if let value = Calculator.evaluate(input) {
                return value.isFinite
            }
            return true
        }
    }

    func testExpressionSoupNeverCrashesAndNeverYieldsNonFinite() throws {
        let soup = Gen<String>.string(
            alphabet: Array("0123456789+-*/%^()., \t"),
            length: 0...40
        )
        try checkProperty("expression soup stays safe", soup, runs: 1_000) { input in
            if let value = Calculator.evaluate(input) {
                return value.isFinite
            }
            return true
        }
    }

    func testEvaluationIsDeterministic() throws {
        let soup = Gen<String>.string(alphabet: Array("0123456789+-*/%^().,"), length: 1...20)
        try checkProperty("same input, same answer", soup) { input in
            Calculator.evaluate(input) == Calculator.evaluate(input)
        }
    }

    func testAdversarialCorpusRejectedExpressionsAllReturnNil() {
        for expression in AdversarialCorpus.rejectedExpressions {
            XCTAssertNil(
                Calculator.evaluate(expression),
                "'\(expression)' must be rejected"
            )
        }
    }

    // MARK: - Documented parser behaviors (surprising but deliberate)

    func testUnaryMinusBindsTighterThanPower() {
        // parsePower calls parseUnary, so "-2 ^ 2" is "(-2) ^ 2" = 4 —
        // the opposite of the standard math convention (-2² = -4).
        XCTAssertEqual(Calculator.evaluate("-2 ^ 2"), 4)
        XCTAssertEqual(Calculator.evaluate("(-2) ^ 2"), 4)
        XCTAssertEqual(Calculator.evaluate("(-2) ^ 3"), -8)
        XCTAssertEqual(Calculator.evaluate("-(2 ^ 2)"), -4)
    }

    func testSignedBareNumberEvaluatesButUnsignedBareNumberDoesNot() {
        // looksLikeExpression demands an operator character; a leading
        // sign satisfies that check, so "-5" is an "expression" but "5" isn't.
        XCTAssertEqual(Calculator.evaluate("-5"), -5)
        XCTAssertEqual(Calculator.evaluate("+5"), 5)
        XCTAssertEqual(Calculator.evaluate("-0"), 0)
        XCTAssertNil(Calculator.evaluate("5"))
        XCTAssertNil(Calculator.evaluate("42"))
        XCTAssertNil(Calculator.evaluate("3.14"))
    }

    func testUnarySignAfterBinaryOperatorIsAccepted() {
        XCTAssertEqual(Calculator.evaluate("1 - - 2"), 3)
        XCTAssertEqual(Calculator.evaluate("1 * + 2"), 2)
        XCTAssertEqual(Calculator.evaluate("1 * - 2"), -2)
        XCTAssertEqual(Calculator.evaluate("6 / - 2"), -3)
    }

    func testScientificAndHexNotationAreRejected() {
        XCTAssertNil(Calculator.evaluate("1e308 + 1"))
        XCTAssertNil(Calculator.evaluate("1.5e3 * 2"))
        XCTAssertNil(Calculator.evaluate("2E5 + 1"))
        XCTAssertNil(Calculator.evaluate("0x10 + 1"))
    }

    func testCommasAreStrippedAnywhereNotJustAsGrouping() {
        // The parser removes every comma without validating grouping.
        XCTAssertEqual(Calculator.evaluate("1,000 + 1"), 1_001)
        XCTAssertEqual(Calculator.evaluate("1,0,0,0 + 1"), 1_001)
        XCTAssertEqual(Calculator.evaluate("1,,2 + 3"), 15)
    }

    // MARK: - Division and modulo by zero

    func testDivisionAndModuloByZeroReturnNil() {
        XCTAssertNil(Calculator.evaluate("1 / 0"))
        XCTAssertNil(Calculator.evaluate("0 / 0"))
        XCTAssertNil(Calculator.evaluate("100 / (5 - 5)"))
        XCTAssertNil(Calculator.evaluate("1 / 0 + 1"))
        XCTAssertNil(Calculator.evaluate("10 % 0"))
        XCTAssertNil(Calculator.evaluate("10 % (5 - 5)"))
    }

    // MARK: - Non-finite results are rejected

    func testOverflowToInfinityIsRejected() {
        XCTAssertNil(Calculator.evaluate("10 ^ 400"))
        XCTAssertNil(Calculator.evaluate("-10 ^ 400"))
        XCTAssertNil(Calculator.evaluate("10 ^ 308 * 10 ^ 308"))
    }

    // MARK: - Malformed expressions

    func testMalformedExpressionsReturnNil() {
        let malformed = [
            "", "   ", "\t\n",
            "+", "*", "-", "/", "^", "%",
            "1 +", "1 -", "1 *", "1 /", "1 ^", "1 %",
            "* 1", "/ 1", "^ 1", "% 1",
            "1 + * 2", "1 / / 2", "1 * / 2", "1 ^ * 2",
            "(1 + 2", "((1 + 2)", "(((1 + 2)",
            "1 + 2)", "(1 + 2))", "(1 + 2)))",
            "()", "1 + ()", "() + 1",
            "abc", "1 + abc", "sin(1)", "pi",
            "1.2.3 + 1", "1..0 + 1",
        ]
        for expression in malformed {
            XCTAssertNil(Calculator.evaluate(expression), "'\(expression)' must be nil")
        }
    }

    // MARK: - Nesting and length stress

    func testDeeplyNestedParentheses() {
        let depth = 200
        var expr = String(repeating: "(", count: depth) + "1"
        for _ in 0..<depth {
            expr += ")"
        }
        XCTAssertEqual(Calculator.evaluate(expr), 1)
    }

    func testDeeplyNestedAddition() {
        let depth = 100
        var expr = String(repeating: "(", count: depth) + "1"
        for _ in 0..<depth {
            expr += " + 1)"
        }
        XCTAssertEqual(Calculator.evaluate(expr), Double(depth + 1))
    }

    func testLongAdditionChain() {
        let count = 2_000
        let expr = (0..<count).map(\.description).joined(separator: " + ")
        XCTAssertEqual(Calculator.evaluate(expr), Double(count * (count - 1) / 2))
    }

    func testLongChainEvaluatesQuickly() {
        let count = 5_000
        let expr = (1...count).map(\.description).joined(separator: " + ")
        let start = ContinuousClock.now
        XCTAssertEqual(Calculator.evaluate(expr), Double(count * (count + 1) / 2))
        XCTAssertLessThan(
            start.duration(to: .now), .seconds(1),
            "a \(count)-term chain must evaluate in well under a second"
        )
    }

    // MARK: - Complex valid expressions

    func testComplexExpressions() {
        XCTAssertEqual(Calculator.evaluate("2 + 3 * 4 - 5 / 5"), 2 + 12 - 1)
        XCTAssertEqual(Calculator.evaluate("(1 + 2) * (3 + 4) / (5 - 2)"), 3 * 7 / 3)
        XCTAssertEqual(Calculator.evaluate("2 ^ 3 ^ 2"), 512) // right-associative
        XCTAssertEqual(Calculator.evaluate("10 % 3 + 2 ^ 3"), 1 + 8)
        XCTAssertEqual(Calculator.evaluate("-(2 + 3) * -(4 - 1)"), -5 * -3)
        XCTAssertEqual(
            Calculator.evaluate("((1 + 2) * (3 + 4)) - ((5 + 6) * (7 + 8))"),
            3 * 7 - 11 * 15
        )
        XCTAssertEqual(Calculator.evaluate("2 ^ -1"), 0.5)
    }

    func testWhitespaceVariants() {
        XCTAssertEqual(Calculator.evaluate("1+2"), 3)
        XCTAssertEqual(Calculator.evaluate(" 1 + 2 "), 3)
        XCTAssertEqual(Calculator.evaluate("1\t+\t2"), 3)
        XCTAssertEqual(Calculator.evaluate("1\n+\n2"), 3)
        XCTAssertEqual(Calculator.evaluate("  1  +  2  "), 3)
    }

    // MARK: - Format

    func testFormatBasics() throws {
        try skipUnlessDotDecimalLocale()
        XCTAssertEqual(Calculator.format(42), "42")
        XCTAssertEqual(Calculator.format(0), "0")
        XCTAssertEqual(Calculator.format(-1), "-1")
        XCTAssertEqual(Calculator.format(0.5), "0.5")
        XCTAssertEqual(Calculator.format(1.25), "1.25")
        XCTAssertEqual(Calculator.format(-3.14), "-3.14")
        XCTAssertEqual(Calculator.format(1.0), "1")
        XCTAssertEqual(Calculator.format(1.10), "1.1")
    }

    func testFormatAppliesGroupingSeparator() {
        let formatted = Calculator.format(1_234_567)
        let separator = Locale.current.groupingSeparator ?? ","
        XCTAssertTrue(
            formatted.contains(separator),
            "format(1234567) = '\(formatted)' should contain the locale grouping separator"
        )
    }

    func testFormatOfClassicFloatSurprise() throws {
        try skipUnlessDotDecimalLocale()
        // 0.1 + 0.2 = 0.30000000000000004, but format caps at 10 fraction
        // digits, so the user sees "0.3".
        let value = try XCTUnwrap(Calculator.evaluate("0.1 + 0.2"))
        XCTAssertEqual(Calculator.format(value), "0.3")
    }

    func testFormatOutputParsesBackToApproximatelyTheInput() throws {
        try skipUnlessDotDecimalLocale()
        try checkProperty("format output re-parses", .double(in: -1_000_000...1_000_000)) { value in
            let formatted = Calculator.format(value)
            let stripped = formatted.replacingOccurrences(of: ",", with: "")
            guard let parsed = Double(stripped) else { return false }
            return abs(parsed - value) < 1e-6
        }
    }

    // MARK: - Helpers

    private func formatExpression(
        _ leftOperand: Double,
        _ operatorSymbol: String,
        _ rightOperand: Double
    ) -> String {
        "\(num(leftOperand)) \(operatorSymbol) \(num(rightOperand))"
    }

    /// `String(Double)` switches to scientific notation below 1e-4, which
    /// the parser rejects — pin generated operands to plain decimal.
    private func num(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var formatted = String(format: "%.10f", value)
        while formatted.hasSuffix("0") {
            formatted.removeLast()
        }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return formatted
    }

    /// Compares two expression strings (or an expression and an expected
    /// value) with tolerance. A `nil` evaluation is a failed property:
    /// every generator here produces valid expressions.
    private func evalEqual(
        _ expression: String,
        _ other: String,
        accuracy: Double
    ) -> Bool {
        guard let lhs = Calculator.evaluate(expression),
              let rhs = Calculator.evaluate(other)
        else {
            return false
        }
        return abs(lhs - rhs) <= accuracy
    }

    private func evalEqual(
        _ expression: String,
        _ expected: Double,
        accuracy: Double
    ) -> Bool {
        guard let lhs = Calculator.evaluate(expression) else { return false }
        return abs(lhs - expected) <= accuracy
    }

    private func skipUnlessDotDecimalLocale() throws {
        try XCTSkipUnless(
            Locale.current.decimalSeparator == ".",
            "NumberFormatter output is locale-dependent; this assertion assumes a '.' decimal separator"
        )
    }
}
