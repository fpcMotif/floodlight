import Foundation
import XCTest
@testable import FloodlightEngine

/// Stress tests for the calculator: deep nesting, long chains, boundary
/// values, and the parser's rejection rules.
///
/// `Calculator.evaluate` returns `Double?`, so every comparison goes through
/// `assertEvalEqual`, which fails the test if the expression didn't parse
/// at all rather than comparing `nil` against a number.
final class CalculatorStressTests: XCTestCase {
    // MARK: - Helpers

    /// Unwraps the optional result before comparing, so a parse failure
    /// surfaces as a clear "expression failed to parse" message instead of
    /// a misleading `nil != value` failure.
    private func assertEvalEqual(
        _ lhs: Double?,
        _ rhs: Double,
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let lhs else {
            XCTFail("expression failed to parse (expected \(rhs))", file: file, line: line)
            return
        }
        XCTAssertEqual(lhs, rhs, accuracy: accuracy, file: file, line: line)
    }

    private let accuracy = 1e-6

    // MARK: - Deep nesting

    func testDeeplyNestedParenthesesAt50Levels() {
        let depth = 50
        let open = String(repeating: "(", count: depth)
        let close = String(repeating: ")", count: depth)
        assertEvalEqual(Calculator.evaluate("\(open)1\(close)"), 1, accuracy: accuracy)
    }

    func testDeeplyNestedAdditionAt50Levels() {
        let depth = 50
        var expr = "1"
        for _ in 0..<depth {
            expr = "(\(expr) + 1)"
        }
        assertEvalEqual(Calculator.evaluate(expr), Double(depth + 1), accuracy: accuracy)
    }

    func testDeeplyNestedMultiplicationAt50Levels() {
        let depth = 50
        var expr = "1"
        for _ in 0..<depth {
            expr = "(\(expr) * 2)"
        }
        assertEvalEqual(Calculator.evaluate(expr), pow(2.0, Double(depth)), accuracy: 1e-3)
    }

    func testAlternatingOperatorsInDeepNesting() {
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

    func testLongChainOf200Additions() {
        let count = 200
        let expr = (0..<count).map { _ in "1" }.joined(separator: " + ")
        assertEvalEqual(Calculator.evaluate(expr), Double(count), accuracy: accuracy)
    }

    func testLongChainOf200Subtractions() {
        let count = 200
        let expr = (0..<count).map { _ in "1" }.joined(separator: " - ")
        // 1 - 1 - 1 - ... (199 subtractions after the first 1) = 1 - 199 = -198
        assertEvalEqual(Calculator.evaluate(expr), Double(1 - (count - 1)), accuracy: accuracy)
    }

    func testLongChainOfMixedAdditionAndMultiplication() {
        let count = 100
        // 1 + 2 * 1 + 2 * 1 + 2 ... — precedence means 2 * 1 = 2 each, so
        // 1 + (2) + (2) + ... 100 times = 1 + 100 * 2 = 201
        var expr = "1"
        for _ in 0..<count {
            expr += " + 2 * 1"
        }
        assertEvalEqual(Calculator.evaluate(expr), Double(1 + count * 2), accuracy: accuracy)
    }

    func testLongChainOfOnesWithTrailingOperatorIsRejected() {
        let expr = (0..<200).map { _ in "1" }.joined(separator: " + ") + " +"
        XCTAssertNil(Calculator.evaluate(expr))
    }

    // MARK: - Boundary values

    func testZeroOperands() {
        assertEvalEqual(Calculator.evaluate("0 + 0"), 0, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("0 * 0"), 0, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("0 ^ 0"), 1, accuracy: accuracy)
    }

    func testLargeIntegerOperands() {
        assertEvalEqual(Calculator.evaluate("1000000 + 1000000"), 2_000_000, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("999999999 * 2"), 1_999_999_998, accuracy: accuracy)
    }

    func testVeryLargePowerProducesInfinityAndIsRejected() {
        // 10 ^ 400 overflows Double to infinity, which the isFinite check rejects.
        XCTAssertNil(Calculator.evaluate("10 ^ 400"))
    }

    func testScientificNotationIsRejected() {
        // The parser doesn't understand 'e' notation and looksLikeExpression
        // rejects letters.
        XCTAssertNil(Calculator.evaluate("1e308 + 1"))
        XCTAssertNil(Calculator.evaluate("1e-5"))
    }

    func testMaxIntegerExpression() {
        assertEvalEqual(
            Calculator.evaluate("9 + 9 + 9 + 9 + 9 + 9 + 9 + 9 + 9 + 9"),
            90,
            accuracy: accuracy
        )
    }

    // MARK: - Division by zero

    func testDivisionByZeroIsRejected() {
        XCTAssertNil(Calculator.evaluate("1 / 0"))
        XCTAssertNil(Calculator.evaluate("0 / 0"))
        XCTAssertNil(Calculator.evaluate("100 / 0"))
    }

    func testModuloByZeroIsRejected() {
        XCTAssertNil(Calculator.evaluate("1 % 0"))
        XCTAssertNil(Calculator.evaluate("0 % 0"))
    }

    func testDivisionByZeroInsideExpressionRejectsTheWholeThing() {
        XCTAssertNil(Calculator.evaluate("1 + 2 / 0 + 3"))
    }

    // MARK: - Invalid expressions

    func testEmptyStringIsRejected() {
        XCTAssertNil(Calculator.evaluate(""))
    }

    func testWhitespaceOnlyIsRejected() {
        XCTAssertNil(Calculator.evaluate("   "))
        XCTAssertNil(Calculator.evaluate("\t\n"))
    }

    func testBareNumberIsRejected() {
        XCTAssertNil(Calculator.evaluate("42"))
        XCTAssertNil(Calculator.evaluate("3.14"))
    }

    func testTrailingOperatorIsRejected() {
        XCTAssertNil(Calculator.evaluate("1 +"))
        XCTAssertNil(Calculator.evaluate("2 *"))
        XCTAssertNil(Calculator.evaluate("3 ^"))
    }

    func testLeadingOperatorWithoutOperandIsRejected() {
        XCTAssertNil(Calculator.evaluate("* 2"))
        XCTAssertNil(Calculator.evaluate("/ 2"))
    }

    func testUnbalancedParenthesesAreRejected() {
        XCTAssertNil(Calculator.evaluate("(1 + 2"))
        XCTAssertNil(Calculator.evaluate("1 + 2)"))
        XCTAssertNil(Calculator.evaluate("((1 + 2)"))
        XCTAssertNil(Calculator.evaluate("(1 + 2))"))
    }

    func testEmptyParenthesesAreRejected() {
        XCTAssertNil(Calculator.evaluate("()"))
        XCTAssertNil(Calculator.evaluate("1 + ()"))
    }

    func testLettersAreRejected() {
        XCTAssertNil(Calculator.evaluate("1 + abc"))
        XCTAssertNil(Calculator.evaluate("abc + 1"))
    }

    func testDoubleDecimalPointIsRejected() {
        XCTAssertNil(Calculator.evaluate("1.2.3 + 1"))
    }

    // MARK: - Unary minus binding

    func testUnaryMinusBindsTighterThanPower() {
        // The parser gives unary minus tighter binding than ^ (parsePower
        // calls parseUnary), so -2 ^ 2 == (-2) ^ 2 == 4, NOT -4.
        assertEvalEqual(Calculator.evaluate("-2 ^ 2"), 4, accuracy: accuracy)
    }

    func testParenthesizedPowerThenUnaryMinus() {
        // -(2 ^ 2) == -4
        assertEvalEqual(Calculator.evaluate("-(2 ^ 2)"), -4, accuracy: accuracy)
    }

    func testDoubleUnaryMinus() {
        assertEvalEqual(Calculator.evaluate("--2"), 2, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("---2"), -2, accuracy: accuracy)
    }

    func testUnaryMinusInMultiplication() {
        assertEvalEqual(Calculator.evaluate("2 * -3"), -6, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("-2 * -3"), 6, accuracy: accuracy)
    }

    // MARK: - Format edge cases

    func testFormatHandlesZero() {
        XCTAssertEqual(Calculator.format(0), "0")
    }

    func testFormatHandlesNegativeNumbers() {
        XCTAssertEqual(Calculator.format(-1), "-1")
        XCTAssertEqual(Calculator.format(-1000), "-1,000")
    }

    func testFormatHandlesLargeNumbers() {
        XCTAssertEqual(Calculator.format(1_000_000), "1,000,000")
    }

    func testFormatHandlesDecimals() {
        XCTAssertEqual(Calculator.format(1234.5), "1,234.5")
    }

    func testFormatTrimsTrailingZeros() {
        XCTAssertEqual(Calculator.format(1.5), "1.5")
        XCTAssertEqual(Calculator.format(100.0), "100")
    }

    // MARK: - Precedence

    func testMultiplicationBindsTighterThanAddition() {
        assertEvalEqual(Calculator.evaluate("2 + 3 * 4"), 14, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("2 * 3 + 4"), 10, accuracy: accuracy)
    }

    func testPowerBindsTighterThanMultiplication() {
        assertEvalEqual(Calculator.evaluate("2 * 3 ^ 2"), 18, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("3 ^ 2 * 2"), 18, accuracy: accuracy)
    }

    func testRightAssociativePower() {
        // 2 ^ 3 ^ 2 == 2 ^ (3 ^ 2) == 2 ^ 9 == 512
        assertEvalEqual(Calculator.evaluate("2 ^ 3 ^ 2"), 512, accuracy: accuracy)
    }

    func testParenthesesOverridePrecedence() {
        assertEvalEqual(Calculator.evaluate("(2 + 3) * 4"), 20, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("(2 + 3) ^ 2"), 25, accuracy: accuracy)
    }

    // MARK: - Unicode operators

    func testUnicodeOperatorsParseCorrectly() {
        assertEvalEqual(Calculator.evaluate("2 × 3"), 6, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("10 ÷ 2"), 5, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("−5 + 10"), 5, accuracy: accuracy)
    }

    func testMixedUnicodeAndAsciiOperators() {
        assertEvalEqual(Calculator.evaluate("2 × 3 + 4"), 10, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("10 ÷ 2 − 3"), 2, accuracy: accuracy)
    }

    // MARK: - Comma handling

    func testThousandsSeparatorsAreStripped() {
        assertEvalEqual(Calculator.evaluate("1,000 + 2,000"), 3000, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("1,000,000 / 1,000"), 1000, accuracy: accuracy)
    }

    func testCommasAreStrippedBeforeParsing() {
        // "1,5 + 1" — the comma is removed, yielding "15 + 1" = 16, not 1.5 + 1.
        assertEvalEqual(Calculator.evaluate("1,5 + 1"), 16, accuracy: accuracy)
    }

    func testBareCommaNumberWithNoOperatorIsRejected() {
        // "1,5" has no operator, so looksLikeExpression rejects it outright.
        XCTAssertNil(Calculator.evaluate("1,5"))
    }

    // MARK: - Whitespace

    func testNoWhitespaceAroundOperators() {
        assertEvalEqual(Calculator.evaluate("1+2"), 3, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("2*3"), 6, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("2^3"), 8, accuracy: accuracy)
    }

    func testExcessiveWhitespaceAroundOperators() {
        assertEvalEqual(Calculator.evaluate("  1   +   2  "), 3, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("1\t+\t2"), 3, accuracy: accuracy)
    }

    // MARK: - Modulo

    func testModuloOfExactDivision() {
        assertEvalEqual(Calculator.evaluate("10 % 5"), 0, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("100 % 10"), 0, accuracy: accuracy)
    }

    func testModuloOfNonExactDivision() {
        assertEvalEqual(Calculator.evaluate("10 % 3"), 1, accuracy: accuracy)
        assertEvalEqual(Calculator.evaluate("17 % 5"), 2, accuracy: accuracy)
    }

    func testModuloChainedWithAddition() {
        assertEvalEqual(Calculator.evaluate("10 % 3 + 1"), 2, accuracy: accuracy)
    }
}
