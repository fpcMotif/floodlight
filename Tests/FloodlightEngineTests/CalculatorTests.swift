import Testing
@testable import FloodlightEngine

struct CalculatorTests {
    @Test func operatorPrecedence() {
        #expect(Calculator.evaluate("2 + 3 * 4") == 14)
    }

    @Test func parenthesesAndPower() {
        #expect(Calculator.evaluate("(2 + 3) ^ 2") == 25)
    }

    @Test func unaryAndDecimal() {
        #expect(Calculator.evaluate("-1.5 * 4") == -6)
    }

    @Test func rejectsPlainNumberAndInvalidExpression() {
        #expect(Calculator.evaluate("42") == nil)
        #expect(Calculator.evaluate("2 +") == nil)
        #expect(Calculator.evaluate("1 / 0") == nil)
    }

    @Test func formatting() {
        #expect(Calculator.format(1_234.5) == "1,234.5")
    }
}
