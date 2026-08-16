import Foundation
import Testing
@testable import FloodlightEngine

/// Stress tests for the calculator: deep nesting, long chains, boundary
/// values, and the parser's rejection rules.
///
/// `Calculator.evaluate` returns `Double?`, so every comparison goes through
/// `assertEvalEqual`, which fails the test if the expression didn't parse
/// at all rather than comparing `nil` against a number.
struct CalculatorStressTests {
    // MARK: - Helpers

    /// Unwraps the optional result before comparing, so a parse failure
    /// surfaces as a clear "expression failed to parse" message instead of
    /// a misleading `nil != value` failure.
    private func assertEvalEqual(
        _ lhs: Double?,
        _ rhs: Double,
        accuracy: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let lhs else {
            Issue.record(
                "expression failed to parse (expected \(rhs))",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(abs(lhs - rhs) <= accuracy, sourceLocation: sourceLocation)
    }

    private let accuracy = 1e-6

    // MARK: - Deep nesting

    @Test func deeplyNestedParenthesesAt50Levels() {
        let depth = 50
        let open = String(repeating: "(", count: depth)
        let close = String(repeating: ")", count: depth)
        assertEvalEqual(Calculator.evaluate("\(open)1\(close)"), 1, accuracy: accuracy)
    }

    @Test func deeplyNestedAdditionAt50Levels() {
        let depth = 50
        var expr = "1"
        for _ in 0..<depth {
            expr = "(\(expr) + 1)"
        }
        assertEvalEqual(Calculator.evaluate(expr), Double(depth + 1), accuracy: accuracy)
    }

    @Test func deeplyNestedMultiplicationAt50Levels() {
        let depth = 50
        var expr = "1"
        for _ in 0..<depth {
            expr = "(\(expr) * 2)"
        }
        assertEvalEqual(Calculator.evaluate(expr), pow(2.0, Double(depth)), accuracy: 1e-3)
    }

    @Test func alternatingOperatorsInDeepNesting() {
        let depth = 50
        var expr = "1"
        for index in 0..<depth {
            let op = index.isMultiple(of: 2) ? "+" : "-"
            expr = "(\(expr) \(op) 1)"
        }
        // 25 additions and 25 subtractions starting from 1 -> 1
        assertEvalEqual(Calculator.evaluate(expr), 1, accuracy: accuracy)
    }

    // MARK: - Long chains

    @Test func longChainOf200Additions() {
        let count = 200
        let expr = (0..<count).map { _ in "1" }.joined(separator: " + ")
        assertEvalEqual(Calculator.evaluate(expr), Double(count), accuracy: accuracy)
    }

    @Test func longChainOf200Subtractions() {
        let count = 200
        let expr = (0..<count).map { _ in "1" }.joined(separator: " - ")
        // 1 - 1 - 1 - ... (199 subtractions after the first 1) = 1 - 199 = -198
        assertEvalEqual(Calculator.evaluate(expr), Double(1 - (count - 1)), accuracy: accuracy)
    }

    @Test func longChainOfMixedAdditionAndMultiplication() {
        let count = 100
        // 1 + 2 * 1 + 2 * 1 + 2 ... — precedence means 2 * 1 = 2 each, so
        // 1 + (2) + (2) + ... 100 times = 1 + 100 * 2 = 201
        var expr = "1"
        for _ in 0..<count {
            expr += " + 2 * 1"
        }
        assertEvalEqual(Calculator.evaluate(expr), Double(1 + count * 2), accuracy: accuracy)
    }

    @Test func longChainOfOnesWithTrailingOperatorIsRejected() {
        let expr = (0..<200).map { _ in "1" }.joined(separator: " + ") + " +"
        #expect(Calculator.evaluate(expr) == nil)
    }

    // MARK: - Boundary values

    @Test func zeroOperands() {
        assertEvalEqual(Calculator.evaluate("0 + 0"), 0, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("0 * 0"), 0, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("0 ^ 0"), 1, accuracy: accuracy)
    }

    @Test func largeIntegerOperands() {
        assertEvalEqual(Calculator.evaluate("1000000 + 1000000"), 2_000_000, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("999999999 * 2"), 1_999_999_998, accuracy: accuracy)
    }

    @Test func veryLargePowerProducesInfinityAndIsRejected() {
        // 10 ^ 400 overflows Double to infinity, which the isFinite check rejects.
        #expect(Calculator.evaluate("10 ^ 400") == nil)
    }

    @Test func scientificNotationIsRejected() {
        // The parser doesn't understand 'e' notation and looksLikeExpression
        // rejects letters.
        #expect(Calculator.evaluate("1e308 + 1") == nil)
        #expect(Calculator.evaluate("1e-5") == nil)
    }

    @Test func maxIntegerExpression() {
        assertEvalEqual(
            Calculator.evaluate("9 + 9 + 9 + 9 + 9 + 9 + 9 + 9 + 9 + 9"),
            90,
            accuracy: accuracy
        )
    }

    // MARK: - Division by zero

    @Test func divisionByZeroIsRejected() {
        #expect(Calculator.evaluate("1 / 0") == nil)
        #expect(Calculator.evaluate("0 / 0") == nil)
        #expect(Calculator.evaluate("100 / 0") == nil)
    }

    @Test func moduloByZeroIsRejected() {
        #expect(Calculator.evaluate("1 % 0") == nil)
        #expect(Calculator.evaluate("0 % 0") == nil)
    }

    @Test func divisionByZeroInsideExpressionRejectsTheWholeThing() {
        #expect(Calculator.evaluate("1 + 2 / 0 + 3") == nil)
    }

    // MARK: - Invalid expressions

    @Test func emptyStringIsRejected() {
        #expect(Calculator.evaluate("") == nil)
    }

    @Test func whitespaceOnlyIsRejected() {
        #expect(Calculator.evaluate("   ") == nil)
        #expect(Calculator.evaluate("\t\n") == nil)
    }

    @Test func bareNumberIsRejected() {
        #expect(Calculator.evaluate("42") == nil)
        #expect(Calculator.evaluate("3.14") == nil)
    }

    @Test func trailingOperatorIsRejected() {
        #expect(Calculator.evaluate("1 +") == nil)
        #expect(Calculator.evaluate("2 *") == nil)
        #expect(Calculator.evaluate("3 ^") == nil)
    }

    @Test func leadingOperatorWithoutOperandIsRejected() {
        #expect(Calculator.evaluate("* 2") == nil)
        #expect(Calculator.evaluate("/ 2") == nil)
    }

    @Test func unbalancedParenthesesAreRejected() {
        #expect(Calculator.evaluate("(1 + 2") == nil)
        #expect(Calculator.evaluate("1 + 2)") == nil)
        #expect(Calculator.evaluate("((1 + 2)") == nil)
        #expect(Calculator.evaluate("(1 + 2))") == nil)
    }

    @Test func emptyParenthesesAreRejected() {
        #expect(Calculator.evaluate("()") == nil)
        #expect(Calculator.evaluate("1 + ()") == nil)
    }

    @Test func lettersAreRejected() {
        #expect(Calculator.evaluate("1 + abc") == nil)
        #expect(Calculator.evaluate("abc + 1") == nil)
    }

    @Test func doubleDecimalPointIsRejected() {
        #expect(Calculator.evaluate("1.2.3 + 1") == nil)
    }

    // MARK: - Unary minus binding

    @Test func unaryMinusBindsTighterThanPower() {
        // The parser gives unary minus tighter binding than ^ (parsePower
        // calls parseUnary), so -2 ^ 2 == (-2) ^ 2 == 4, NOT -4.
        assertEvalEqual(Calculator.evaluate("-2 ^ 2"), 4, accuracy: accuracy)
    }

    @Test func parenthesizedPowerThenUnaryMinus() {
        // -(2 ^ 2) == -4
        assertEvalEqual(Calculator.evaluate("-(2 ^ 2)"), -4, accuracy: accuracy)
    }

    @Test func doubleUnaryMinus() {
        assertEvalEqual(Calculator.evaluate("--2"), 2, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("---2"), -2, accuracy: accuracy)
    }

    @Test func unaryMinusInMultiplication() {
        assertEvalEqual(Calculator.evaluate("2 * -3"), -6, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("-2 * -3"), 6, accuracy: accuracy)
    }

    // MARK: - Format edge cases

    @Test func formatHandlesZero() {
        #expect(Calculator.format(0) == "0")
    }

    @Test func formatHandlesNegativeNumbers() {
        #expect(Calculator.format(-1) == "-1")
        #expect(Calculator.format(-1_000) == "-1,000")
    }

    @Test func formatHandlesLargeNumbers() {
        #expect(Calculator.format(1_000_000) == "1,000,000")
    }

    @Test func formatHandlesDecimals() {
        #expect(Calculator.format(1_234.5) == "1,234.5")
    }

    @Test func formatTrimsTrailingZeros() {
        #expect(Calculator.format(1.5) == "1.5")
        #expect(Calculator.format(100.0) == "100")
    }

    // MARK: - Precedence

    @Test func multiplicationBindsTighterThanAddition() {
        assertEvalEqual(Calculator.evaluate("2 + 3 * 4"), 14, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("2 * 3 + 4"), 10, accuracy: accuracy)
    }

    @Test func powerBindsTighterThanMultiplication() {
        assertEvalEqual(Calculator.evaluate("2 * 3 ^ 2"), 18, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("3 ^ 2 * 2"), 18, accuracy: accuracy)
    }

    @Test func rightAssociativePower() {
        // 2 ^ 3 ^ 2 == 2 ^ (3 ^ 2) == 2 ^ 9 == 512
        assertEvalEqual(Calculator.evaluate("2 ^ 3 ^ 2"), 512, accuracy: accuracy)
    }

    @Test func parenthesesOverridePrecedence() {
        assertEvalEqual(Calculator.evaluate("(2 + 3) * 4"), 20, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("(2 + 3) ^ 2"), 25, accuracy: accuracy)
    }

    // MARK: - Unicode operators

    @Test func unicodeOperatorsParseCorrectly() {
        assertEvalEqual(Calculator.evaluate("2 × 3"), 6, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("10 ÷ 2"), 5, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("−5 + 10"), 5, accuracy: accuracy)
    }

    @Test func mixedUnicodeAndAsciiOperators() {
        assertEvalEqual(Calculator.evaluate("2 × 3 + 4"), 10, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("10 ÷ 2 − 3"), 2, accuracy: accuracy)
    }

    // MARK: - Comma handling

    @Test func thousandsSeparatorsAreStripped() {
        assertEvalEqual(Calculator.evaluate("1,000 + 2,000"), 3_000, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("1,000,000 / 1,000"), 1_000, accuracy: accuracy)
    }

    @Test func commasAreStrippedBeforeParsing() {
        // "1,5 + 1" — the comma is removed, yielding "15 + 1" = 16, not 1.5 + 1.
        assertEvalEqual(Calculator.evaluate("1,5 + 1"), 16, accuracy: accuracy)
    }

    @Test func bareCommaNumberWithNoOperatorIsRejected() {
        // "1,5" has no operator, so looksLikeExpression rejects it outright.
        #expect(Calculator.evaluate("1,5") == nil)
    }

    // MARK: - Whitespace

    @Test func noWhitespaceAroundOperators() {
        assertEvalEqual(Calculator.evaluate("1+2"), 3, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("2*3"), 6, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("2^3"), 8, accuracy: accuracy)
    }

    @Test func excessiveWhitespaceAroundOperators() {
        assertEvalEqual(Calculator.evaluate("  1   +   2  "), 3, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("1\t+\t2"), 3, accuracy: accuracy)
    }

    // MARK: - Modulo

    @Test func moduloOfExactDivision() {
        assertEvalEqual(Calculator.evaluate("10 % 5"), 0, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("100 % 10"), 0, accuracy: accuracy)
    }

    @Test func moduloOfNonExactDivision() {
        assertEvalEqual(Calculator.evaluate("10 % 3"), 1, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("17 % 5"), 2, accuracy: accuracy)
    }

    @Test func moduloChainedWithAddition() {
        assertEvalEqual(Calculator.evaluate("10 % 3 + 1"), 2, accuracy: accuracy)
    }
}
