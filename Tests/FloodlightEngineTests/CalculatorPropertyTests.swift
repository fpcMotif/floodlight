import FloodlightTestSupport
import Foundation
import XCTest
@testable import FloodlightEngine

/// Property-based tests for the calculator.
///
/// The calculator is a tiny recursive-descent parser, so the properties
/// that matter are the algebraic identities it should preserve under
/// floating point: commutativity, associativity, distributivity, and the
/// identity elements. Whitespace invariance and unicode-operator
/// equivalence cover the normalization layer that runs before parsing.
final class CalculatorPropertyTests: XCTestCase {
    // MARK: - Helpers

    /// Formats a double the way a human writes it — whole numbers without a
    /// trailing `.0` — so the generated expressions stay readable in a
    /// counterexample message.
    private func formatNum(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int64(value))
            : String(value)
    }

    /// A double generator kept in a range where the parser's integer
    /// arithmetic and `pow` stay exact enough to compare with `accuracy`.
    private let smallDouble = Gen<Double>.double(in: -1_000...1_000)

    private let nonzeroDouble = Gen<Double>.double(in: -1_000...1_000)
        .filter { abs($0) > 0.5 }

    private let positiveDouble = Gen<Double>.double(in: 0.5...1_000)

    // MARK: - Commutativity

    func testAdditionIsCommutative() throws {
        try checkProperty(
            "a + b == b + a",
            smallDouble,
            smallDouble,
            runs: 400
        ) { left, right in
            let lhs = Calculator.evaluate("\(formatNum(left)) + \(formatNum(right))")
            let rhs = Calculator.evaluate("\(formatNum(right)) + \(formatNum(left))")
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    func testMultiplicationIsCommutative() throws {
        try checkProperty(
            "a * b == b * a",
            smallDouble,
            smallDouble,
            runs: 400
        ) { left, right in
            let lhs = Calculator.evaluate("\(formatNum(left)) * \(formatNum(right))")
            let rhs = Calculator.evaluate("\(formatNum(right)) * \(formatNum(left))")
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    // MARK: - Associativity

    func testAdditionIsAssociative() throws {
        try checkProperty(
            "(a + b) + c == a + (b + c)",
            smallDouble,
            smallDouble,
            smallDouble,
            runs: 400
        ) { first, second, third in
            let lhs = Calculator.evaluate(
                "(\(formatNum(first)) + \(formatNum(second))) + \(formatNum(third))"
            )
            let rhs = Calculator.evaluate(
                "\(formatNum(first)) + (\(formatNum(second)) + \(formatNum(third)))"
            )
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    func testMultiplicationIsAssociative() throws {
        try checkProperty(
            "(a * b) * c == a * (b * c)",
            smallDouble,
            smallDouble,
            smallDouble,
            runs: 400
        ) { first, second, third in
            let lhs = Calculator.evaluate(
                "(\(formatNum(first)) * \(formatNum(second))) * \(formatNum(third))"
            )
            let rhs = Calculator.evaluate(
                "\(formatNum(first)) * (\(formatNum(second)) * \(formatNum(third)))"
            )
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    // MARK: - Distributivity

    func testMultiplicationDistributesOverAddition() throws {
        try checkProperty(
            "a * (b + c) == a * b + a * c",
            smallDouble,
            smallDouble,
            smallDouble,
            runs: 400
        ) { multiplier, firstAddend, secondAddend in
            let lhs = Calculator.evaluate(
                "\(formatNum(multiplier)) * (\(formatNum(firstAddend)) + \(formatNum(secondAddend)))"
            )
            let rhs = Calculator
                .evaluate(
                    "\(formatNum(multiplier)) * \(formatNum(firstAddend))"
                        + " + \(formatNum(multiplier)) * \(formatNum(secondAddend))"
                )
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-4
        }
    }

    // MARK: - Identity

    func testAdditiveIdentity() throws {
        try checkProperty(
            "a + 0 == a",
            smallDouble,
            runs: 400
        ) { operand in
            guard let result = Calculator.evaluate("\(formatNum(operand)) + 0") else { return true }
            return abs(result - operand) < 1e-6
        }
    }

    func testMultiplicativeIdentity() throws {
        try checkProperty(
            "a * 1 == a",
            smallDouble,
            runs: 400
        ) { operand in
            guard let result = Calculator.evaluate("\(formatNum(operand)) * 1") else { return true }
            return abs(result - operand) < 1e-6
        }
    }

    func testSubtractiveIdentity() throws {
        try checkProperty(
            "a - 0 == a",
            smallDouble,
            runs: 400
        ) { operand in
            guard let result = Calculator.evaluate("\(formatNum(operand)) - 0") else { return true }
            return abs(result - operand) < 1e-6
        }
    }

    // MARK: - Negation

    func testUnaryNegationIsAnInvolution() throws {
        try checkProperty(
            "-(-a) == a",
            smallDouble,
            runs: 400
        ) { operand in
            guard let result = Calculator.evaluate("-(-\(formatNum(operand)))") else { return true }
            return abs(result - operand) < 1e-6
        }
    }

    func testNegationFlipsTheSign() throws {
        try checkProperty(
            "-a == 0 - a",
            smallDouble,
            runs: 400
        ) { operand in
            let lhs = Calculator.evaluate("-\(formatNum(operand))")
            let rhs = Calculator.evaluate("0 - \(formatNum(operand))")
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    // MARK: - Power

    func testPowerOfTwoMatchesSquaring() throws {
        try checkProperty(
            "a ^ 2 == a * a",
            smallDouble,
            runs: 400
        ) { operand in
            let lhs = Calculator.evaluate("\(formatNum(operand)) ^ 2")
            let rhs = Calculator.evaluate("\(formatNum(operand)) * \(formatNum(operand))")
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-4
        }
    }

    func testPowerOfOneIsIdentity() throws {
        try checkProperty(
            "a ^ 1 == a",
            smallDouble,
            runs: 400
        ) { operand in
            guard let result = Calculator.evaluate("\(formatNum(operand)) ^ 1") else { return true }
            return abs(result - operand) < 1e-6
        }
    }

    // MARK: - Modulo

    func testModuloIsLessThanDivisor() throws {
        try checkProperty(
            "a % b < b for positive b",
            positiveDouble,
            positiveDouble,
            runs: 400
        ) { dividend, divisor in
            guard let result = Calculator.evaluate(
                "\(formatNum(dividend)) % \(formatNum(divisor))"
            ) else {
                return true
            }
            return result < divisor && result >= 0
        }
    }

    func testModuloOfExactMultipleIsZero() throws {
        // Stated over *integers*. With `Double` operands the property is
        // simply false: `a * b` rounds, and the truncating remainder of a
        // rounded product is a value just under `b` about as often as it is
        // zero. Rounding is a property of binary floating point, not a bug
        // in the parser, so the identity is asserted where it holds.
        let factor = Gen<Int>.int(in: 1...5_000)
        let divisor = Gen<Int>.int(in: 1...5_000)
        try checkProperty(
            "(a * b) % b == 0 for integers",
            factor,
            divisor,
            runs: 400
        ) { generatedFactor, generatedDivisor in
            let product = generatedFactor * generatedDivisor
            guard let result = Calculator.evaluate("\(product) % \(generatedDivisor)") else {
                return false
            }
            return result == 0
        }
    }

    func testModuloOfAFloatingProductIsNotReliablyZero() throws {
        // The counterexample to the integer identity above, pinned so the
        // limitation is documented rather than rediscovered: 192.08… ×
        // 577.39… does not divide evenly once rounded.
        let product = 192.08361966676026 * 577.3971575676518
        let remainder = try XCTUnwrap(
            Calculator.evaluate("\(product) % \(577.3971575676518)")
        )
        XCTAssertGreaterThan(remainder, 0)
        XCTAssertLessThan(remainder, 577.3971575676518)
    }

    // MARK: - Whitespace invariance

    func testWhitespaceBetweenTokensDoesNotChangeTheResult() throws {
        let spacingGen = Gen<String>.element(of: ["", " ", "  ", "\t", " \t "])
        try checkProperty(
            "a <sp> + <sp> b == a + b regardless of spacing",
            PropertyGenerators4(
                first: smallDouble,
                second: smallDouble,
                third: spacingGen,
                fourth: spacingGen
            ),
            runs: 400
        ) { leftOperand, rightOperand, leftGap, rightGap in
            let lhs = Calculator.evaluate(
                "\(formatNum(leftOperand))\(leftGap)+\(rightGap)\(formatNum(rightOperand))"
            )
            let rhs = Calculator.evaluate(
                "\(formatNum(leftOperand)) + \(formatNum(rightOperand))"
            )
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    func testLeadingAndTrailingWhitespaceIsIgnored() throws {
        let paddingGen = Gen<String>.element(of: ["", "  ", "\n", " \n "])
        try checkProperty(
            "padded 'a + b' == 'a + b'",
            PropertyGenerators4(
                first: smallDouble,
                second: smallDouble,
                third: paddingGen,
                fourth: paddingGen
            ),
            runs: 400
        ) { leftOperand, rightOperand, leadingPadding, trailingPadding in
            let lhs = Calculator.evaluate(
                "\(leadingPadding)\(formatNum(leftOperand))"
                    + " + \(formatNum(rightOperand))\(trailingPadding)"
            )
            let rhs = Calculator.evaluate(
                "\(formatNum(leftOperand)) + \(formatNum(rightOperand))"
            )
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    // MARK: - Unicode operator equivalence

    func testUnicodeMultiplicationSignMatchesAsterisk() throws {
        try checkProperty(
            "a × b == a * b",
            smallDouble,
            smallDouble,
            runs: 400
        ) { left, right in
            let lhs = Calculator.evaluate("\(formatNum(left)) × \(formatNum(right))")
            let rhs = Calculator.evaluate("\(formatNum(left)) * \(formatNum(right))")
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    func testUnicodeDivisionSignMatchesSlash() throws {
        try checkProperty(
            "a ÷ b == a / b",
            smallDouble,
            nonzeroDouble,
            runs: 400
        ) { dividend, divisor in
            let lhs = Calculator.evaluate("\(formatNum(dividend)) ÷ \(formatNum(divisor))")
            let rhs = Calculator.evaluate("\(formatNum(dividend)) / \(formatNum(divisor))")
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    func testUnicodeMinusSignMatchesHyphen() throws {
        try checkProperty(
            "−a == 0 - a",
            smallDouble,
            runs: 400
        ) { operand in
            let lhs = Calculator.evaluate("−\(formatNum(operand))")
            let rhs = Calculator.evaluate("0 - \(formatNum(operand))")
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    // MARK: - Comma handling

    func testThousandsCommasDoNotChangeTheResult() throws {
        try checkProperty(
            "'1,000 + a' == '1000 + a'",
            smallDouble,
            runs: 400
        ) { operand in
            let lhs = Calculator.evaluate("1,000 + \(formatNum(operand))")
            let rhs = Calculator.evaluate("1000 + \(formatNum(operand))")
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    func testCommasInBothOperandsAreStripped() throws {
        try checkProperty(
            "'1,234 + 5,678' == '1234 + 5678'",
            Gen<Int>.always(0),
            runs: 400
        ) { _ in
            let lhs = Calculator.evaluate("1,234 + 5,678")
            let rhs = Calculator.evaluate("1234 + 5678")
            guard let lhs, let rhs else { return true }
            return abs(lhs - rhs) < 1e-6
        }
    }

    // MARK: - Format round-trip

    func testFormatPreservesWholeNumbers() {
        XCTAssertEqual(Calculator.format(1_000), "1,000")
        XCTAssertEqual(Calculator.format(0), "0")
        XCTAssertEqual(Calculator.format(-42), "-42")
    }

    func testFormatUsesGroupingSeparator() {
        XCTAssertEqual(Calculator.format(1_234_567), "1,234,567")
    }
}

// MARK: - Three-argument checkProperty overload

/// Local helper so the associativity/distributivity properties can take
/// three generators without pulling a generic triple into the shared
/// harness. Generates the three values independently and shrinks each.
private func checkProperty<A, B, C>(
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
    let triple = Gen<(A, B, C)>(
        generate: { rng in
            (first.generate(&rng), second.generate(&rng), third.generate(&rng))
        },
        shrink: { tuple in
            first.shrink(tuple.0).map { ($0, tuple.1, tuple.2) }
                + second.shrink(tuple.1).map { (tuple.0, $0, tuple.2) }
                + third.shrink(tuple.2).map { (tuple.0, tuple.1, $0) }
        }
    )
    try checkProperty(description, triple, runs: runs, seed: seed, file: file, line: line) {
        try property($0.0, $0.1, $0.2)
    }
}

private struct PropertyGenerators4<
    First: Sendable,
    Second: Sendable,
    Third: Sendable,
    Fourth: Sendable
>: Sendable {
    let first: Gen<First>
    let second: Gen<Second>
    let third: Gen<Third>
    let fourth: Gen<Fourth>
}

private struct PropertyValues4<
    First: Sendable,
    Second: Sendable,
    Third: Sendable,
    Fourth: Sendable
>: Sendable {
    let first: First
    let second: Second
    let third: Third
    let fourth: Fourth
}

/// Four-value form for whitespace properties. Named values keep the generator
/// and shrink paths clear without a large tuple or a wide helper signature.
private func checkProperty<A: Sendable, B: Sendable, C: Sendable, D: Sendable>(
    _ description: String,
    _ generators: PropertyGenerators4<A, B, C, D>,
    runs: Int = defaultPropertyRuns,
    seed: UInt64 = 0xF100_D116_4700_0004,
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (A, B, C, D) throws -> Bool
) throws {
    let values = Gen<PropertyValues4<A, B, C, D>>(
        generate: { rng in
            PropertyValues4(
                first: generators.first.generate(&rng),
                second: generators.second.generate(&rng),
                third: generators.third.generate(&rng),
                fourth: generators.fourth.generate(&rng)
            )
        },
        shrink: { values in
            generators.first.shrink(values.first).map {
                PropertyValues4(
                    first: $0,
                    second: values.second,
                    third: values.third,
                    fourth: values.fourth
                )
            }
                + generators.second.shrink(values.second).map {
                    PropertyValues4(
                        first: values.first,
                        second: $0,
                        third: values.third,
                        fourth: values.fourth
                    )
                }
                + generators.third.shrink(values.third).map {
                    PropertyValues4(
                        first: values.first,
                        second: values.second,
                        third: $0,
                        fourth: values.fourth
                    )
                }
                + generators.fourth.shrink(values.fourth).map {
                    PropertyValues4(
                        first: values.first,
                        second: values.second,
                        third: values.third,
                        fourth: $0
                    )
                }
        }
    )
    try checkProperty(description, values, runs: runs, seed: seed, file: file, line: line) {
        try property($0.first, $0.second, $0.third, $0.fourth)
    }
}
