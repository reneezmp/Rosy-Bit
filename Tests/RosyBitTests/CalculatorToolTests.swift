import XCTest
@testable import RosyBit

final class CalculatorToolTests: XCTestCase {
    func testArithmeticPrecedenceParenthesesAndExponentiation() throws {
        XCTAssertEqual(try CalculatorTool.result(for: "2 + 3 * 4"), "**14**")
        XCTAssertEqual(try CalculatorTool.result(for: "(2 + 3) * 4"), "**20**")
        XCTAssertEqual(try CalculatorTool.result(for: "2 ^ 10"), "**1024**")
    }

    func testPercentageUsesExactNativeEvaluation() throws {
        XCTAssertEqual(try CalculatorTool.result(for: "15% of 80"), "**12**")
        XCTAssertEqual(try CalculatorTool.result(for: "200 * 10%"), "**20**")
    }

    func testCommonUnitsAndTemperatureConvert() throws {
        XCTAssertEqual(
            try CalculatorTool.result(for: "1000 g to kg"),
            "**1000 g = 1 kg**")
        XCTAssertEqual(
            try CalculatorTool.result(for: "32 °f to °c"),
            "**32 °F = 0 °C**")
        XCTAssertEqual(
            try CalculatorTool.result(for: "how many miles are 10 km"),
            "**10 km = 6.213711922 mi**")
        XCTAssertEqual(
            try CalculatorTool.result(for: "Convert 6 feet to cm"),
            "**6 ft = 182.88 cm**")
        XCTAssertEqual(
            try CalculatorTool.result(for: "convert 180 ºC to ºF"),
            "**180 °C = 356 °F**")
        XCTAssertEqual(
            try CalculatorTool.result(for: "convert from 68 degrees Fahrenheit into Celsius"),
            "**68 °F = 20 °C**")
        XCTAssertEqual(
            try CalculatorTool.result(for: "convert 20˚C to °F"),
            "**20 °C = 68 °F**")
    }

    func testRejectsCodeUnknownSyntaxAndIncompatibleUnits() {
        XCTAssertThrowsError(try CalculatorTool.result(for: "system('open Safari')"))
        XCTAssertThrowsError(try CalculatorTool.result(for: "10 kg to miles")) { error in
            XCTAssertEqual(error as? CalculatorTool.ToolError, .incompatibleUnits)
        }
        XCTAssertThrowsError(try CalculatorTool.result(for: "1 / 0")) { error in
            XCTAssertEqual(error as? CalculatorTool.ToolError, .divisionByZero)
        }
    }

    func testExplicitRouterIsNarrowAndTimestampAware() {
        XCTAssertEqual(
            CalculatorTool.explicitQuery(
                in: "[Timestamp: 2026-08-31 21:00 GMT-3]\nCalculate 9 * 7"),
            "9 * 7")
        XCTAssertEqual(
            CalculatorTool.explicitQuery(in: "Convert 500 ml to liters"),
            "500 ml to liters")
        XCTAssertNil(CalculatorTool.explicitQuery(in: "I bought 2 apples and 3 pears."))
        XCTAssertNil(CalculatorTool.explicitQuery(in: "Calculate this:\n2 + 2"))
    }

    func testToolArgumentsAreStrict() throws {
        XCTAssertEqual(
            try CalculatorTool.parse(id: nil, arguments: #"{"query":"2+2"}"#).query,
            "2+2")
        XCTAssertThrowsError(try CalculatorTool.parse(
            id: nil,
            arguments: #"{"query":"2+2","extra":true}"#))
    }
}
