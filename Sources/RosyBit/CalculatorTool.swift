import Foundation

/// A deliberately small calculator: arithmetic and a fixed unit catalogue,
/// never a scripting language. The model can supply only a string which this
/// parser must accept completely before any result is produced.
enum CalculatorTool {
    static let name = "calculator_calculate"

    static let schema: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": name,
            "description": "Calculate arithmetic or convert common units exactly. Use this for numerical calculations, percentages, and conversions. Pass only the calculation itself, for example '15% of 80' or '10 km to miles'.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "A short arithmetic expression or unit conversion."
                    ]
                ],
                "required": ["query"],
                "additionalProperties": false
            ]
        ]
    ]]

    struct Call: Equatable {
        let id: String
        let query: String
        let rawArguments: String
    }

    enum ToolError: LocalizedError, Equatable {
        case malformedArguments
        case unsupportedCalculation
        case divisionByZero
        case incompatibleUnits

        var errorDescription: String? {
            switch self {
            case .malformedArguments:
                return "Rosy produced an invalid calculator request."
            case .unsupportedCalculation:
                return "That calculation uses syntax or units Rosy's safe calculator does not support yet."
            case .divisionByZero:
                return "That calculation divides by zero."
            case .incompatibleUnits:
                return "Those units measure different kinds of things and cannot be converted."
            }
        }
    }

    static func parse(id: String?, arguments: String) throws -> Call {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["query"],
              let raw = object["query"] as? String else {
            throw ToolError.malformedArguments
        }
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 160,
              !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ToolError.malformedArguments }
        return Call(
            id: id?.isEmpty == false ? id! : "calculator-call",
            query: query,
            rawArguments: arguments)
    }

    /// Routes only plainly authored, single-line calculations. Ordinary prose
    /// containing numbers remains ordinary conversation.
    static func explicitQuery(in message: String) -> String? {
        guard let prompt = singleUserLine(message) else { return nil }
        let patterns = [
            #"^(?:please\s+)?(?:calculate|compute|work\s+out)\s+(.+?)(?:,?\s+please)?[?!.]*$"#,
            #"^(?:please\s+)?what(?:'s|\s+is)\s+(-?[0-9][0-9\s.,+\-*/×÷^()%]*)(?:,?\s+please)?[?!.]*$"#,
            #"^(?:please\s+)?what(?:'s|\s+is)\s+(-?[0-9]+(?:\.[0-9]+)?%\s+of\s+-?[0-9]+(?:\.[0-9]+)?)(?:,?\s+please)?[?!.]*$"#,
            #"^(?:please\s+)?convert\s+(.+?)(?:,?\s+please)?[?!.]*$"#,
            #"^(?:please\s+)?how\s+many\s+[a-zA-Z°]+\s+(?:are|is)\s+-?[0-9].+?[?!.]*$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
            guard let match = regex.firstMatch(in: prompt, range: range) else { continue }
            if match.numberOfRanges == 2,
               let capture = Range(match.range(at: 1), in: prompt) {
                return String(prompt[capture])
            }
            return prompt
        }
        return nil
    }

    static func result(for query: String) throws -> String {
        if let conversion = try conversionResult(for: query) { return conversion }

        var expression = query
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        expression = expression.replacingOccurrences(
            of: #"(?i)^\s*(?:calculate|compute|what(?:'s|\s+is))\s+"#,
            with: "",
            options: .regularExpression)
        expression = expression.replacingOccurrences(
            of: #"(?i)(-?[0-9]+(?:\.[0-9]+)?)\s*%\s+of\s+(-?[0-9]+(?:\.[0-9]+)?)"#,
            with: "($1 / 100) * $2",
            options: .regularExpression)
        expression = expression.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "?!.")))
        guard expression.count <= 160 else { throw ToolError.unsupportedCalculation }

        var parser = ExpressionParser(expression)
        let value = try parser.parse()
        return "**\(formatted(value))**"
    }

    static func observation(query: String, result: String) -> String {
        "Authoritative local calculator result for \(query): \(result.replacingOccurrences(of: "**", with: ""))"
    }

    private static func conversionResult(for raw: String) throws -> String? {
        let query = raw.lowercased()
            // People and keyboards commonly use the masculine ordinal `º` or
            // ring `˚` in place of the actual degree sign `°`. Treat all three
            // as equivalent before parsing, while the unit allowlist below
            // remains the authority on what may be converted.
            .replacingOccurrences(of: "º", with: "°")
            .replacingOccurrences(of: "˚", with: "°")
            // The word form already identifies a temperature unit (`C`,
            // `Celsius`, `F`, or `Fahrenheit`), so discard the prose prefix.
            .replacingOccurrences(of: #"\bdegrees?\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\bfrom\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "?!.")))
        let patterns = [
            #"^(?:convert\s+)?(-?[0-9]+(?:\.[0-9]+)?)\s*([a-z°]+)\s+(?:to|in|into)\s+([a-z°]+)$"#,
            #"^how\s+many\s+([a-z°]+)\s+(?:are|is|in)\s+(-?[0-9]+(?:\.[0-9]+)?)\s*([a-z°]+)$"#,
        ]

        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: query,
                    range: NSRange(query.startIndex..<query.endIndex, in: query))
            else { continue }
            func capture(_ number: Int) -> String? {
                Range(match.range(at: number), in: query).map { String(query[$0]) }
            }
            let valueText = capture(index == 0 ? 1 : 2)
            let sourceText = capture(index == 0 ? 2 : 3)
            let targetText = capture(index == 0 ? 3 : 1)
            guard let valueText, let value = Double(valueText), value.isFinite,
                  let sourceText, let source = unit(named: sourceText),
                  let targetText, let target = unit(named: targetText)
            else { throw ToolError.unsupportedCalculation }
            guard source.dimension == target.dimension else {
                throw ToolError.incompatibleUnits
            }
            let base = (value + source.offset) * source.scale
            let converted = (base / target.scale) - target.offset
            guard converted.isFinite else { throw ToolError.unsupportedCalculation }
            return "**\(formatted(value)) \(source.symbol) = \(formatted(converted)) \(target.symbol)**"
        }
        return nil
    }

    private struct UnitDefinition {
        let dimension: String
        let symbol: String
        let scale: Double
        let offset: Double
    }

    private static func unit(named raw: String) -> UnitDefinition? {
        let key = raw.lowercased()
            .replacingOccurrences(of: "º", with: "°")
            .replacingOccurrences(of: "˚", with: "°")
            .trimmingCharacters(in: .whitespaces)
        let definitions: [([String], UnitDefinition)] = [
            (["mm", "millimeter", "millimeters", "millimetre", "millimetres"], .init(dimension: "length", symbol: "mm", scale: 0.001, offset: 0)),
            (["cm", "centimeter", "centimeters", "centimetre", "centimetres"], .init(dimension: "length", symbol: "cm", scale: 0.01, offset: 0)),
            (["m", "meter", "meters", "metre", "metres"], .init(dimension: "length", symbol: "m", scale: 1, offset: 0)),
            (["km", "kilometer", "kilometers", "kilometre", "kilometres"], .init(dimension: "length", symbol: "km", scale: 1_000, offset: 0)),
            (["in", "inch", "inches"], .init(dimension: "length", symbol: "in", scale: 0.0254, offset: 0)),
            (["ft", "foot", "feet"], .init(dimension: "length", symbol: "ft", scale: 0.3048, offset: 0)),
            (["yd", "yard", "yards"], .init(dimension: "length", symbol: "yd", scale: 0.9144, offset: 0)),
            (["mi", "mile", "miles"], .init(dimension: "length", symbol: "mi", scale: 1_609.344, offset: 0)),
            (["mg", "milligram", "milligrams"], .init(dimension: "mass", symbol: "mg", scale: 0.001, offset: 0)),
            (["g", "gram", "grams"], .init(dimension: "mass", symbol: "g", scale: 1, offset: 0)),
            (["kg", "kilogram", "kilograms"], .init(dimension: "mass", symbol: "kg", scale: 1_000, offset: 0)),
            (["oz", "ounce", "ounces"], .init(dimension: "mass", symbol: "oz", scale: 28.349523125, offset: 0)),
            (["lb", "lbs", "pound", "pounds"], .init(dimension: "mass", symbol: "lb", scale: 453.59237, offset: 0)),
            (["ml", "milliliter", "milliliters", "millilitre", "millilitres"], .init(dimension: "volume", symbol: "mL", scale: 1, offset: 0)),
            (["l", "liter", "liters", "litre", "litres"], .init(dimension: "volume", symbol: "L", scale: 1_000, offset: 0)),
            (["tsp", "teaspoon", "teaspoons"], .init(dimension: "volume", symbol: "tsp", scale: 4.92892159375, offset: 0)),
            (["tbsp", "tablespoon", "tablespoons"], .init(dimension: "volume", symbol: "tbsp", scale: 14.78676478125, offset: 0)),
            (["cup", "cups"], .init(dimension: "volume", symbol: "US cup", scale: 236.5882365, offset: 0)),
            (["s", "sec", "second", "seconds"], .init(dimension: "time", symbol: "s", scale: 1, offset: 0)),
            (["min", "minute", "minutes"], .init(dimension: "time", symbol: "min", scale: 60, offset: 0)),
            (["h", "hr", "hour", "hours"], .init(dimension: "time", symbol: "h", scale: 3_600, offset: 0)),
            (["day", "days"], .init(dimension: "time", symbol: "days", scale: 86_400, offset: 0)),
            (["b", "byte", "bytes"], .init(dimension: "data", symbol: "B", scale: 1, offset: 0)),
            (["kb", "kilobyte", "kilobytes"], .init(dimension: "data", symbol: "KB", scale: 1_000, offset: 0)),
            (["mb", "megabyte", "megabytes"], .init(dimension: "data", symbol: "MB", scale: 1_000_000, offset: 0)),
            (["gb", "gigabyte", "gigabytes"], .init(dimension: "data", symbol: "GB", scale: 1_000_000_000, offset: 0)),
            (["tb", "terabyte", "terabytes"], .init(dimension: "data", symbol: "TB", scale: 1_000_000_000_000, offset: 0)),
            (["°c", "c", "celsius", "centigrade"], .init(dimension: "temperature", symbol: "°C", scale: 1, offset: 0)),
            (["°f", "f", "fahrenheit"], .init(dimension: "temperature", symbol: "°F", scale: 5 / 9, offset: -32)),
            (["k", "kelvin"], .init(dimension: "temperature", symbol: "K", scale: 1, offset: -273.15)),
        ]
        return definitions.first(where: { $0.0.contains(key) })?.1
    }

    private static func formatted(_ value: Double) -> String {
        if abs(value) < 0.000000000001 { return "0" }
        if value.rounded() == value, abs(value) < 1e15 {
            return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        return String(format: "%.10g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func singleUserLine(_ message: String) -> String? {
        var lines = message.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("[Timestamp:") == true { lines.removeFirst() }
        guard lines.count == 1 else { return nil }
        return lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ExpressionParser {
        private enum Token: Equatable {
            case number(Double), plus, minus, multiply, divide, power
            case leftParen, rightParen, percent, end
        }

        private let characters: [Character]
        private var index = 0
        private var current: Token = .end

        init(_ expression: String) {
            characters = Array(expression)
        }

        mutating func parse() throws -> Double {
            current = try nextToken()
            let result = try parseExpression()
            guard current == .end, result.isFinite else {
                throw ToolError.unsupportedCalculation
            }
            return result
        }

        private mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while true {
                switch current {
                case .plus:
                    current = try nextToken(); value += try parseTerm()
                case .minus:
                    current = try nextToken(); value -= try parseTerm()
                default: return value
                }
            }
        }

        private mutating func parseTerm() throws -> Double {
            var value = try parsePower()
            while true {
                switch current {
                case .multiply:
                    current = try nextToken(); value *= try parsePower()
                case .divide:
                    current = try nextToken()
                    let divisor = try parsePower()
                    guard divisor != 0 else { throw ToolError.divisionByZero }
                    value /= divisor
                default: return value
                }
            }
        }

        private mutating func parsePower() throws -> Double {
            var value = try parseUnary()
            if current == .power {
                current = try nextToken()
                value = Foundation.pow(value, try parsePower())
            }
            return value
        }

        private mutating func parseUnary() throws -> Double {
            if current == .plus { current = try nextToken(); return try parseUnary() }
            if current == .minus { current = try nextToken(); return -(try parseUnary()) }
            return try parsePrimary()
        }

        private mutating func parsePrimary() throws -> Double {
            var value: Double
            switch current {
            case .number(let number):
                value = number
                current = try nextToken()
            case .leftParen:
                current = try nextToken()
                value = try parseExpression()
                guard current == .rightParen else { throw ToolError.unsupportedCalculation }
                current = try nextToken()
            default:
                throw ToolError.unsupportedCalculation
            }
            while current == .percent {
                value /= 100
                current = try nextToken()
            }
            return value
        }

        private mutating func nextToken() throws -> Token {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { return .end }
            let character = characters[index]
            index += 1
            switch character {
            case "+": return .plus
            case "-": return .minus
            case "*": return .multiply
            case "/": return .divide
            case "^": return .power
            case "(": return .leftParen
            case ")": return .rightParen
            case "%": return .percent
            default:
                guard character.isNumber || character == "." else {
                    throw ToolError.unsupportedCalculation
                }
                var text = String(character)
                while index < characters.count,
                      characters[index].isNumber || characters[index] == "." {
                    text.append(characters[index]); index += 1
                }
                guard text.filter({ $0 == "." }).count <= 1,
                      let value = Double(text), value.isFinite else {
                    throw ToolError.unsupportedCalculation
                }
                return .number(value)
            }
        }
    }
}
