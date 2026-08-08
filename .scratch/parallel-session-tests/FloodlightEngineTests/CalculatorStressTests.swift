import Foundation
import XCTest
@testable import FloodlightEngine

/// Harsh, critical stress tests for `Calculator` — adversarial inputs,
/// deep nesting, boundary values, and pathological expressions designed
/// to break a naive recursive-descent parser.
final class CalculatorStressTests: XCTestCase {

    // MARK: - Deep nesting

    func testDeeplyNestedParentheses() {
        let depth = 50
        var expr = String(repeating: "(", count: depth) + "1"
        for _ in 0..<depth { expr += ")" }
        XCTAssertEqual(Calculator.evaluate(expr), 1)
    }

    func testDeeplyNestedAddition() {
        let depth = 30
        var expr = String(repeating: "(", count: depth) + "1"
        for _ in 0..<depth { expr += " + 1)" }
        XCTAssertEqual(Calculator.evaluate(expr), Double(depth + 1))
    }

    func testAlternatingParenthesesAndOperators() {
        let result = Calculator.evaluate("((1 + 2) * (3 + 4)) - ((5 + 6) * (7 + 8))")
        XCTAssertEqual(result, 3 * 7 - 11 * 15)
    }

    // MARK: - Long expressions

    func testLongAdditionChain() {
        let count = 200
        let expr = (0..<count).map(\.description).joined(separator: " + ")
        XCTAssertEqual(Calculator.evaluate(expr), Double(count * (count - 1) / 2))
    }

    func testLongMultiplicationChain() {
        let expr = String(repeating: "2 * ", count: 9) + "2"
        XCTAssertEqual(Calculator.evaluate(expr), pow(2.0, 10))
    }

    func testMixedLongChain() {
        var expr = "1"
        for i in 2...100 {
            expr += i.isMultiple(of: 3) ? " * \(i)" : " + \(i)"
        }
        XCTAssertNotNil(Calculator.evaluate(expr))
    }

    // MARK: - Boundary values

    func testVeryLargeNumbers() {
        XCTAssertNotNil(Calculator.evaluate("10 ^ 300 + 1"))
        XCTAssertNotNil(Calculator.evaluate("9999999999999999 + 1"))
    }

    func testScientificNotationIsRejected() {
        // The parser has no exponent support, and `looksLikeExpression`
        // rejects letters — "1e308" never reaches the parser.
        XCTAssertNil(Calculator.evaluate("1e308 + 1"))
        XCTAssertNil(Calculator.evaluate("1.5e3 * 2"))
        XCTAssertNil(Calculator.evaluate("2E5 + 1"))
    }

    func testVerySmallNumbers() {
        assertEvalEqual(Calculator.evaluate("0.0000001 + 0.0000001"), 0.0000002, accuracy: 1e-10)
    }

    func testZeroOperations() {
        XCTAssertEqual(Calculator.evaluate("0 + 0"), 0)
        XCTAssertEqual(Calculator.evaluate("0 * 0"), 0)
        XCTAssertEqual(Calculator.evaluate("0 - 0"), 0)
        XCTAssertEqual(Calculator.evaluate("0 ^ 0"), 1)
    }

    func testNegativeBasePower() {
        // This parser gives unary minus TIGHTER binding than `^`
        // (parsePower calls parseUnary), so "-2 ^ 2" is "(-2) ^ 2" = 4 —
        // the opposite of the standard math convention where -2² = -4.
        XCTAssertEqual(Calculator.evaluate("-2 ^ 2"), 4)
        XCTAssertEqual(Calculator.evaluate("(-2) ^ 2"), 4)
        XCTAssertEqual(Calculator.evaluate("(-2) ^ 3"), -8)
        XCTAssertEqual(Calculator.evaluate("-(2 ^ 2)"), -4)
    }

    func testFractionalPowers() {
        assertEvalEqual(Calculator.evaluate("4 ^ 0.5"), 2, accuracy: 0.001)
        assertEvalEqual(Calculator.evaluate("8 ^ (1/3)"), 2, accuracy: 0.001)
    }

    // MARK: - Division by zero

    func testDivisionByZeroReturnsNil() {
        XCTAssertNil(Calculator.evaluate("1 / 0"))
        XCTAssertNil(Calculator.evaluate("0 / 0"))
        XCTAssertNil(Calculator.evaluate("100 / (5 - 5)"))
        XCTAssertNil(Calculator.evaluate("1 / 0 + 1"))
    }

    func testModuloByZeroReturnsNil() {
        XCTAssertNil(Calculator.evaluate("10 % 0"))
        XCTAssertNil(Calculator.evaluate("10 % (5 - 5)"))
    }

    // MARK: - Invalid expressions

    func testEmptyString() {
        XCTAssertNil(Calculator.evaluate(""))
    }

    func testWhitespaceOnly() {
        XCTAssertNil(Calculator.evaluate("   "))
        XCTAssertNil(Calculator.evaluate("\t\n"))
    }

    func testBareOperator() {
        XCTAssertNil(Calculator.evaluate("+"))
        XCTAssertNil(Calculator.evaluate("*"))
        XCTAssertNil(Calculator.evaluate("-"))
        XCTAssertNil(Calculator.evaluate("/"))
        XCTAssertNil(Calculator.evaluate("^"))
        XCTAssertNil(Calculator.evaluate("%"))
    }

    func testTrailingOperator() {
        XCTAssertNil(Calculator.evaluate("1 +"))
        XCTAssertNil(Calculator.evaluate("1 -"))
        XCTAssertNil(Calculator.evaluate("1 *"))
        XCTAssertNil(Calculator.evaluate("1 /"))
        XCTAssertNil(Calculator.evaluate("1 ^"))
        XCTAssertNil(Calculator.evaluate("1 %"))
    }

    func testLeadingOperator() {
        // Unary minus and plus are valid
        XCTAssertNotNil(Calculator.evaluate("-1"))
        XCTAssertNotNil(Calculator.evaluate("+1"))
        // But binary operators are not
        XCTAssertNil(Calculator.evaluate("* 1"))
        XCTAssertNil(Calculator.evaluate("/ 1"))
        XCTAssertNil(Calculator.evaluate("^ 1"))
        XCTAssertNil(Calculator.evaluate("% 1"))
    }

    func testConsecutiveBinaryOperators() {
        XCTAssertNil(Calculator.evaluate("1 + * 2"))
        XCTAssertNil(Calculator.evaluate("1 / / 2"))
        XCTAssertNil(Calculator.evaluate("1 * / 2"))
        XCTAssertNil(Calculator.evaluate("1 ^ * 2"))
    }

    func testUnarySignAfterBinaryOperatorIsAccepted() {
        // parseUnary runs inside every operand position, so a sign right
        // after a binary operator is a valid unary, not a syntax error.
        XCTAssertEqual(Calculator.evaluate("1 - - 2"), 3)
        XCTAssertEqual(Calculator.evaluate("1 * + 2"), 2)
        XCTAssertEqual(Calculator.evaluate("1 * - 2"), -2)
        XCTAssertEqual(Calculator.evaluate("6 / - 2"), -3)
    }

    func testUnmatchedOpenParen() {
        XCTAssertNil(Calculator.evaluate("(1 + 2"))
        XCTAssertNil(Calculator.evaluate("((1 + 2)"))
        XCTAssertNil(Calculator.evaluate("(((1 + 2)"))
    }

    func testUnmatchedCloseParen() {
        XCTAssertNil(Calculator.evaluate("1 + 2)"))
        XCTAssertNil(Calculator.evaluate("(1 + 2))"))
        XCTAssertNil(Calculator.evaluate("(1 + 2)))"))
    }

    func testEmptyParentheses() {
        XCTAssertNil(Calculator.evaluate("()"))
        XCTAssertNil(Calculator.evaluate("1 + ()"))
        XCTAssertNil(Calculator.evaluate("() + 1"))
    }

    func testLettersAndWords() {
        XCTAssertNil(Calculator.evaluate("abc"))
        XCTAssertNil(Calculator.evaluate("1 + abc"))
        XCTAssertNil(Calculator.evaluate("sin(1)"))
        XCTAssertNil(Calculator.evaluate("pi"))
    }

    // MARK: - Plain numbers are rejected

    func testPlainNumberWithoutOperatorIsRejected() {
        XCTAssertNil(Calculator.evaluate("42"))
        XCTAssertNil(Calculator.evaluate("3.14"))
        XCTAssertNil(Calculator.evaluate("0"))
        XCTAssertNil(Calculator.evaluate("999"))
    }

    // MARK: - Format edge cases

    func testFormatInteger() {
        XCTAssertEqual(Calculator.format(42), "42")
        XCTAssertEqual(Calculator.format(0), "0")
        XCTAssertEqual(Calculator.format(-1), "-1")
    }

    func testFormatLargeNumberWithGrouping() {
        let formatted = Calculator.format(1_234_567)
        XCTAssertTrue(formatted.contains(","))
    }

    func testFormatSmallDecimal() {
        XCTAssertEqual(Calculator.format(0.5), "0.5")
        XCTAssertEqual(Calculator.format(1.25), "1.25")
    }

    func testFormatNegativeDecimal() {
        XCTAssertEqual(Calculator.format(-3.14), "-3.14")
    }

    func testFormatTrimsTrailingZeros() {
        XCTAssertEqual(Calculator.format(1.0), "1")
        XCTAssertEqual(Calculator.format(1.10), "1.1")
        XCTAssertEqual(Calculator.format(1.000000), "1")
    }

    // MARK: - Complex valid expressions

    func testComplexExpression1() {
        let result = Calculator.evaluate("2 + 3 * 4 - 5 / 5")
        XCTAssertEqual(result, 2 + 12 - 1)
    }

    func testComplexExpression2() {
        let result = Calculator.evaluate("(1 + 2) * (3 + 4) / (5 - 2)")
        XCTAssertEqual(result, 3 * 7 / 3)
    }

    func testComplexExpression3() {
        let result = Calculator.evaluate("2 ^ 3 ^ 2")
        // Right-associative: 2^(3^2) = 2^9 = 512
        XCTAssertEqual(result, 512)
    }

    func testComplexExpression4() {
        let result = Calculator.evaluate("10 % 3 + 2 ^ 3")
        XCTAssertEqual(result, 1 + 8)
    }

    func testComplexExpression5() {
        let result = Calculator.evaluate("-(2 + 3) * -(4 - 1)")
        XCTAssertEqual(result, -5 * -3)
    }

    // MARK: - Multiple decimal points

    func testMultipleDecimalPointsInOneNumber() {
        XCTAssertNil(Calculator.evaluate("1.2.3 + 1"))
        XCTAssertNil(Calculator.evaluate("1..0 + 1"))
    }

    // MARK: - Whitespace edge cases

    func testAllWhitespaceVariants() {
        XCTAssertEqual(Calculator.evaluate("1+2"), 3)
        XCTAssertEqual(Calculator.evaluate(" 1 + 2 "), 3)
        XCTAssertEqual(Calculator.evaluate("1\t+\t2"), 3)
        XCTAssertEqual(Calculator.evaluate("1\n+\n2"), 3)
        XCTAssertEqual(Calculator.evaluate("  1  +  2  "), 3)
    }

    // MARK: - Infinity and NaN

    func testInfinityFromOverflow() {
        // A very large power should produce infinity, which evaluate rejects
        let result = Calculator.evaluate("10 ^ 400")
        XCTAssertNil(result, "infinity should be rejected as non-finite")
    }

    func testNegativeInfinityRejected() {
        let result = Calculator.evaluate("-10 ^ 400")
        XCTAssertNil(result, "negative infinity should be rejected")
    }

    // MARK: - Helpers

    /// `XCTAssertEqual(_:_:accuracy:)` has no Optional overload — evaluate's
    /// result must be non-nil (every expression above is valid) and within
    /// `accuracy` of the expected value.
    private func assertEvalEqual(
        _ lhs: Double?,
        _ rhs: Double,
        accuracy: Double,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let lhs else {
            XCTFail("expression failed to parse (expected \(rhs)) — \(message())", file: file, line: line)
            return
        }
        XCTAssertEqual(lhs, rhs, accuracy: accuracy, message(), file: file, line: line)
    }
}
