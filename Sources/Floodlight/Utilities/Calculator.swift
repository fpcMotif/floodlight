import Foundation

enum Calculator {
    static func evaluate(_ source: String) -> Double? {
        let normalized = source
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard looksLikeExpression(normalized) else { return nil }
        var parser = Parser(normalized)
        guard let value = parser.parseExpression(), parser.isAtEnd, value.isFinite else {
            return nil
        }
        return value
    }

    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 10
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func looksLikeExpression(_ source: String) -> Bool {
        guard source.contains(where: { "+-*/%^()".contains($0) }) else { return false }
        return source.allSatisfy { $0.isNumber || $0.isWhitespace || ".,+-*/%^()".contains($0) }
    }
}

private struct Parser {
    private let characters: [Character]
    private var index = 0

    init(_ source: String) {
        characters = Array(source.replacingOccurrences(of: ",", with: ""))
    }

    var isAtEnd: Bool {
        var cursor = index
        while cursor < characters.count, characters[cursor].isWhitespace {
            cursor += 1
        }
        return cursor == characters.count
    }

    mutating func parseExpression() -> Double? {
        guard var value = parseTerm() else { return nil }
        while true {
            if consume("+") {
                guard let rhs = parseTerm() else { return nil }
                value += rhs
            } else if consume("-") {
                guard let rhs = parseTerm() else { return nil }
                value -= rhs
            } else {
                return value
            }
        }
    }

    private mutating func parseTerm() -> Double? {
        guard var value = parsePower() else { return nil }
        while true {
            if consume("*") {
                guard let rhs = parsePower() else { return nil }
                value *= rhs
            } else if consume("/") {
                guard let rhs = parsePower(), rhs != 0 else { return nil }
                value /= rhs
            } else if consume("%") {
                guard let rhs = parsePower(), rhs != 0 else { return nil }
                value.formTruncatingRemainder(dividingBy: rhs)
            } else {
                return value
            }
        }
    }

    private mutating func parsePower() -> Double? {
        guard var value = parseUnary() else { return nil }
        if consume("^") {
            guard let exponent = parsePower() else { return nil }
            value = pow(value, exponent)
        }
        return value
    }

    private mutating func parseUnary() -> Double? {
        if consume("-") {
            guard let value = parseUnary() else { return nil }
            return -value
        }
        if consume("+") {
            return parseUnary()
        }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> Double? {
        if consume("(") {
            guard let value = parseExpression(), consume(")") else { return nil }
            return value
        }
        return parseNumber()
    }

    private mutating func parseNumber() -> Double? {
        skipWhitespace()
        let start = index
        var hasDecimal = false

        while index < characters.count {
            let character = characters[index]
            if character.isNumber {
                index += 1
            } else if character == ".", !hasDecimal {
                hasDecimal = true
                index += 1
            } else {
                break
            }
        }

        guard index > start else { return nil }
        return Double(String(characters[start..<index]))
    }

    private mutating func consume(_ expected: Character) -> Bool {
        skipWhitespace()
        guard index < characters.count, characters[index] == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
    }
}
