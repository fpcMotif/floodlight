import XCTest
@testable import FloodlightEngine

final class CalculatorTests: XCTestCase {
    func testOperatorPrecedence() {
        XCTAssertEqual(Calculator.evaluate("2 + 3 * 4"), 14)
    }

    func testParenthesesAndPower() {
        XCTAssertEqual(Calculator.evaluate("(2 + 3) ^ 2"), 25)
    }

    func testUnaryAndDecimal() {
        XCTAssertEqual(Calculator.evaluate("-1.5 * 4"), -6)
    }

    func testRejectsPlainNumberAndInvalidExpression() {
        XCTAssertNil(Calculator.evaluate("42"))
        XCTAssertNil(Calculator.evaluate("2 +"))
        XCTAssertNil(Calculator.evaluate("1 / 0"))
    }

    func testFormatting() {
        XCTAssertEqual(Calculator.format(1_234.5), "1,234.5")
    }
}
