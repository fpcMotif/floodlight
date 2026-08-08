import Foundation
import XCTest
@testable import FloodlightEngine

/// Property-based tests for `Calculator` — randomized inputs that verify
/// algebraic laws and round-trip invariants hold across a wide input space.
/// Each property is exercised with hundreds of randomly generated values.
final class CalculatorPropertyTests: XCTestCase {

    // MARK: - Commutativity

    func testAdditionIsCommutative() {
        for _ in 0..<500 {
            let a = Double.random(in: -10_000...10_000)
            let b = Double.random(in: -10_000...10_000)
            let left = Calculator.evaluate(formatExpression(a, "+", b))
            let right = Calculator.evaluate(formatExpression(b, "+", a))
            assertEvalEqual(left, right, accuracy: 0.001, "a+b should equal b+a for a=\(a), b=\(b)")
        }
    }

    func testMultiplicationIsCommutative() {
        for _ in 0..<500 {
            let a = Double.random(in: -10_000...10_000)
            let b = Double.random(in: -10_000...10_000)
            let left = Calculator.evaluate(formatExpression(a, "*", b))
            let right = Calculator.evaluate(formatExpression(b, "*", a))
            assertEvalEqual(left, right, accuracy: 0.001, "a*b should equal b*a for a=\(a), b=\(b)")
        }
    }

    // MARK: - Associativity

    func testAdditionIsAssociative() {
        for _ in 0..<500 {
            let a = Double.random(in: -1_000...1_000)
            let b = Double.random(in: -1_000...1_000)
            let c = Double.random(in: -1_000...1_000)
            let left = Calculator.evaluate("(\(formatNum(a)) + \(formatNum(b))) + \(formatNum(c))")
            let right = Calculator.evaluate("\(formatNum(a)) + (\(formatNum(b)) + \(formatNum(c))")
            assertEvalEqual(left, right, accuracy: 0.01, "associative addition failed for a=\(a), b=\(b), c=\(c)")
        }
    }

    func testMultiplicationIsAssociative() {
        for _ in 0..<500 {
            let a = Double.random(in: -100...100)
            let b = Double.random(in: -100...100)
            let c = Double.random(in: -100...100)
            let left = Calculator.evaluate("(\(formatNum(a)) * \(formatNum(b))) * \(formatNum(c))")
            let right = Calculator.evaluate("\(formatNum(a)) * (\(formatNum(b)) * \(formatNum(c))")
            assertEvalEqual(left, right, accuracy: 0.01, "associative multiplication failed for a=\(a), b=\(b), c=\(c)")
        }
    }

    // MARK: - Distributivity

    func testMultiplicationDistributesOverAddition() {
        for _ in 0..<500 {
            let a = Double.random(in: -100...100)
            let b = Double.random(in: -100...100)
            let c = Double.random(in: -100...100)
            let left = Calculator.evaluate("\(formatNum(a)) * (\(formatNum(b)) + \(formatNum(c)))")
            let right = Calculator.evaluate("\(formatNum(a)) * \(formatNum(b)) + \(formatNum(a)) * \(formatNum(c))")
            assertEvalEqual(left, right, accuracy: 0.01, "distributivity failed for a=\(a), b=\(b), c=\(c)")
        }
    }

    // MARK: - Identity and zero

    func testAdditiveIdentity() {
        for _ in 0..<300 {
            let a = Double.random(in: -10_000...10_000)
            let result = Calculator.evaluate("\(formatNum(a)) + 0")
            assertEvalEqual(result, a, accuracy: 0.001, "a+0 should equal a for a=\(a)")
        }
    }

    func testMultiplicativeIdentity() {
        for _ in 0..<300 {
            let a = Double.random(in: -10_000...10_000)
            let result = Calculator.evaluate("\(formatNum(a)) * 1")
            assertEvalEqual(result, a, accuracy: 0.001, "a*1 should equal a for a=\(a)")
        }
    }

    func testMultiplicativeZero() {
        for _ in 0..<300 {
            let a = Double.random(in: -10_000...10_000)
            let result = Calculator.evaluate("\(formatNum(a)) * 0")
            assertEvalEqual(result, 0, accuracy: 0.001, "a*0 should equal 0 for a=\(a)")
        }
    }

    // MARK: - Negation

    func testDoubleNegationIsIdentity() {
        for _ in 0..<300 {
            let a = Double.random(in: -10_000...10_000)
            let result = Calculator.evaluate("--\(formatNum(a))")
            assertEvalEqual(result, a, accuracy: 0.001, "--a should equal a for a=\(a)")
        }
    }

    func testNegationFlipsSign() {
        for _ in 0..<300 {
            let a = Double.random(in: -10_000...10_000)
            let positive = Calculator.evaluate(formatNum(a))
            let negative = Calculator.evaluate("-\(formatNum(a))")
            if let positive, let negative {
                XCTAssertEqual(positive + negative, 0, accuracy: 0.001, "a + (-a) should be 0 for a=\(a)")
            }
        }
    }

    // MARK: - Power properties

    func testPowerOfOne() {
        for _ in 0..<300 {
            let a = Double.random(in: -100...100)
            let result = Calculator.evaluate("\(formatNum(a)) ^ 1")
            assertEvalEqual(result, a, accuracy: 0.001, "a^1 should equal a for a=\(a)")
        }
    }

    func testPowerOfTwo() {
        for _ in 0..<300 {
            let a = Double.random(in: -50...50)
            let result = Calculator.evaluate("\(formatNum(a)) ^ 2")
            assertEvalEqual(result, a * a, accuracy: 0.01, "a^2 should equal a*a for a=\(a)")
        }
    }

    func testPowerOfZero() {
        for _ in 0..<300 {
            let a = Double.random(in: 1...100)
            let result = Calculator.evaluate("\(formatNum(a)) ^ 0")
            assertEvalEqual(result, 1, accuracy: 0.001, "a^0 should equal 1 for a=\(a)")
        }
    }

    // MARK: - Subtraction self-cancellation

    func testSelfSubtractionIsZero() {
        for _ in 0..<300 {
            let a = Double.random(in: -10_000...10_000)
            let result = Calculator.evaluate("\(formatNum(a)) - \(formatNum(a))")
            assertEvalEqual(result, 0, accuracy: 0.001, "a-a should equal 0 for a=\(a)")
        }
    }

    // MARK: - Division self-cancellation

    func testSelfDivisionIsOne() {
        for _ in 0..<300 {
            let a = Double.random(in: 1...10_000)
            let result = Calculator.evaluate("\(formatNum(a)) / \(formatNum(a))")
            assertEvalEqual(result, 1, accuracy: 0.001, "a/a should equal 1 for a=\(a)")
        }
    }

    // MARK: - Format / evaluate round-trip

    func testFormatProducesAParsableNumber() {
        for _ in 0..<300 {
            let value = Double.random(in: -1_000_000...1_000_000)
            let formatted = Calculator.format(value)
            // format() adds grouping separators and trims decimals, but the
            // raw number should still be parseable by Swift's Double
            let parsed = Double(formatted.replacingOccurrences(of: ",", with: ""))
            XCTAssertNotNil(parsed, "format(\(value)) produced '\(formatted)' which is not parseable")
        }
    }

    // MARK: - Order of operations

    func testMultiplicationPrecedesAddition() {
        for _ in 0..<300 {
            let a = Double.random(in: -100...100)
            let b = Double.random(in: -100...100)
            let c = Double.random(in: -100...100)
            let result = Calculator.evaluate("\(formatNum(a)) + \(formatNum(b)) * \(formatNum(c))")
            let expected = a + b * c
            assertEvalEqual(result, expected, accuracy: 0.01, "precedence failed for a=\(a), b=\(b), c=\(c)")
        }
    }

    func testPowerPrecedesMultiplication() {
        for _ in 0..<300 {
            let a = Double.random(in: -10...10)
            let b = Double.random(in: 0.5...5)
            let c = Double.random(in: -10...10)
            let result = Calculator.evaluate("\(formatNum(a)) * \(formatNum(b)) ^ \(formatNum(c))")
            let expected = a * pow(b, c)
            assertEvalEqual(result, expected, accuracy: 0.01, "power precedence failed for a=\(a), b=\(b), c=\(c)")
        }
    }

    func testParenthesesOverridePrecedence() {
        for _ in 0..<300 {
            let a = Double.random(in: -100...100)
            let b = Double.random(in: -100...100)
            let c = Double.random(in: -100...100)
            let withParens = Calculator.evaluate("(\(formatNum(a)) + \(formatNum(b))) * \(formatNum(c))")
            let expected = (a + b) * c
            assertEvalEqual(withParens, expected, accuracy: 0.01, "parens override failed for a=\(a), b=\(b), c=\(c)")
        }
    }

    // MARK: - Left-to-right for same-precedence

    func testSubtractionIsLeftAssociative() {
        for _ in 0..<300 {
            let a = Double.random(in: -100...100)
            let b = Double.random(in: -100...100)
            let c = Double.random(in: -100...100)
            let result = Calculator.evaluate("\(formatNum(a)) - \(formatNum(b)) - \(formatNum(c))")
            let expected = a - b - c
            assertEvalEqual(result, expected, accuracy: 0.01, "left-assoc subtraction failed for a=\(a), b=\(b), c=\(c)")
        }
    }

    func testDivisionIsLeftAssociative() {
        for _ in 0..<300 {
            let a = Double.random(in: 1...1_000)
            let b = Double.random(in: 1...1_000)
            let c = Double.random(in: 1...1_000)
            let result = Calculator.evaluate("\(formatNum(a)) / \(formatNum(b)) / \(formatNum(c))")
            let expected = a / b / c
            assertEvalEqual(result, expected, accuracy: 0.01, "left-assoc division failed for a=\(a), b=\(b), c=\(c)")
        }
    }

    // MARK: - Modulo properties

    func testModuloOfSmallerByLargerIsTheSmaller() {
        for _ in 0..<300 {
            let a = Double.random(in: 1...100)
            let b = Double.random(in: 101...1_000)
            let result = Calculator.evaluate("\(formatNum(a)) % \(formatNum(b))")
            assertEvalEqual(result, a, accuracy: 0.001, "a%b where a<b should equal a for a=\(a), b=\(b)")
        }
    }

    func testModuloOfMultipleIsZero() {
        for _ in 0..<300 {
            // Integer operands keep n*k exactly representable, so the
            // truncating remainder is exactly zero.
            let n = Double(Int.random(in: 1...100))
            let k = Double(Int.random(in: 2...20))
            let multiple = n * k
            let result = Calculator.evaluate("\(formatNum(multiple)) % \(formatNum(k))")
            assertEvalEqual(result, 0, accuracy: 0.001, "(n*k)%k should be 0 for n=\(n), k=\(k)")
        }
    }

    // MARK: - Whitespace invariance

    func testWhitespaceDoesNotAffectResult() {
        for _ in 0..<300 {
            let a = Double.random(in: -100...100)
            let b = Double.random(in: -100...100)
            let noSpace = Calculator.evaluate("\(formatNum(a))+\(formatNum(b))")
            let withSpace = Calculator.evaluate("\(formatNum(a)) + \(formatNum(b))")
            let extraSpace = Calculator.evaluate("\(formatNum(a))  +  \(formatNum(b))")
            assertEvalEqual(noSpace, withSpace, accuracy: 0.001)
            assertEvalEqual(withSpace, extraSpace, accuracy: 0.001)
        }
    }

    // MARK: - Unicode operator invariance

    func testUnicodeMultiplicationSignMatchesAsterisk() {
        for _ in 0..<200 {
            let a = Double.random(in: -100...100)
            let b = Double.random(in: -100...100)
            let withUnicode = Calculator.evaluate("\(formatNum(a)) × \(formatNum(b))")
            let withAsterisk = Calculator.evaluate("\(formatNum(a)) * \(formatNum(b))")
            assertEvalEqual(withUnicode, withAsterisk, accuracy: 0.001)
        }
    }

    func testUnicodeDivisionSignMatchesSlash() {
        for _ in 0..<200 {
            let a = Double.random(in: 1...1_000)
            let b = Double.random(in: 1...1_000)
            let withUnicode = Calculator.evaluate("\(formatNum(a)) ÷ \(formatNum(b))")
            let withSlash = Calculator.evaluate("\(formatNum(a)) / \(formatNum(b))")
            assertEvalEqual(withUnicode, withSlash, accuracy: 0.001)
        }
    }

    func testUnicodeMinusSignMatchesHyphen() {
        for _ in 0..<200 {
            let a = Double.random(in: -100...100)
            let withUnicode = Calculator.evaluate("−\(formatNum(a))")
            let withHyphen = Calculator.evaluate("-\(formatNum(a))")
            assertEvalEqual(withUnicode, withHyphen, accuracy: 0.001)
        }
    }

    // MARK: - Comma as thousands separator

    func testCommaThousandsSeparatorDoesNotAffectResult() {
        for _ in 0..<200 {
            let a = Double.random(in: 1_000...999_999)
            let b = Double.random(in: 1...100)
            let withComma = Calculator.evaluate("\(formatWithCommas(a)) + \(formatNum(b))")
            let withoutComma = Calculator.evaluate("\(formatNum(a)) + \(formatNum(b))")
            assertEvalEqual(withComma, withoutComma, accuracy: 0.001)
        }
    }

    // MARK: - Helpers

    private func formatExpression(_ a: Double, _ op: String, _ b: Double) -> String {
        "\(formatNum(a)) \(op) \(formatNum(b))"
    }

    private func formatNum(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        // `String(Double)` switches to scientific notation below 1e-4
        // ("1e-07"), and the parser rejects letters — pin the format to
        // plain decimal so generated expressions always parse.
        var s = String(format: "%.10f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private func formatWithCommas(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// `XCTAssertEqual(_:_:accuracy:)` has no Optional overload, so property
    /// assertions on `Calculator.evaluate` go through here. A `nil` on either
    /// side means the parser rejected a generated expression — itself a
    /// failure, since every generator above produces valid expressions.
    private func assertEvalEqual(
        _ lhs: Double?,
        _ rhs: Double?,
        accuracy: Double,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (lhs, rhs) {
        case (nil, nil):
            XCTFail("both sides failed to parse — \(message())", file: file, line: line)
        case (nil, .some(let r)):
            XCTFail("left side failed to parse (expected \(r)) — \(message())", file: file, line: line)
        case (.some(let l), nil):
            XCTFail("right side failed to parse (got \(l)) — \(message())", file: file, line: line)
        case (.some(let l), .some(let r)):
            XCTAssertEqual(l, r, accuracy: accuracy, message(), file: file, line: line)
        }
    }
}
