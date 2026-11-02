import XCTest
@testable import VaultSSH

final class LocalizationTests: XCTestCase {
    private func localizedBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(L10n.bundle.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    private func strings(_ bundle: Bundle) throws -> [String: String] {
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }

    func testCatalogsHaveMatchingKeysAndFormatArguments() throws {
        let english = try strings(localizedBundle("en"))
        let chinese = try strings(localizedBundle("zh-Hans"))
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let placeholder = try NSRegularExpression(pattern: "%(@|ld)")
        func arguments(_ value: String) -> [String] {
            placeholder.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .map { (value as NSString).substring(with: $0.range) }
        }
        for (key, value) in english {
            let translation = try XCTUnwrap(chinese[key])
            XCTAssertFalse(translation.isEmpty, key)
            XCTAssertEqual(arguments(value), arguments(translation), key)
        }
    }

    func testPluralCountsAndInterpolatedErrors() throws {
        for language in ["en", "zh-Hans"] {
            let bundle = try localizedBundle(language)
            let locale = Locale(identifier: language)
            func format(_ key: String, _ args: CVarArg...) -> String {
                String(format: bundle.localizedString(forKey: key, value: nil, table: nil), locale: locale, arguments: args)
            }
            XCTAssertEqual(format("%ld events", 1), language == "en" ? "1 event" : "1 条")
            XCTAssertEqual(format("%ld events", 2), language == "en" ? "2 events" : "2 条")
            XCTAssertEqual(format("%ld keys available", 1), language == "en" ? "1 key available" : "1 把密钥可用")
            XCTAssertEqual(format("%ld more requests", 2), language == "en" ? "2 more requests" : "另有 2 个请求")
            XCTAssertEqual(format("Could not start the agent: %@", "test-error"),
                           language == "en" ? "Could not start the agent: test-error" : "无法启动 agent：test-error")
        }
    }

    func testReasonCodesWorkWithAnyDiagnosticLanguageAndLegacyLogs() throws {
        func event(_ reason: String?, _ detail: String) throws -> AgentEvent {
            var value = ["time": "2026-11-02T00:00:00Z", "type": "sign", "result": "denied", "detail": detail]
            value["reason"] = reason
            return try JSONDecoder().decode(AgentEvent.self, from: JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertEqual(try event("timeout", "localized elsewhere").resultLabel, L10n.text("Timed Out"))
        XCTAssertEqual(try event("revoked", "localized elsewhere").resultLabel, L10n.text("Revoked"))
        XCTAssertEqual(try event(nil, "等待确认超时（60 秒）").resultLabel, L10n.text("Timed Out"))
        XCTAssertEqual(try event("denied", "超时 is just caller-supplied text").resultLabel, L10n.text("Denied"))
    }
}
