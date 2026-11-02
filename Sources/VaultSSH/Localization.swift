import Foundation

enum L10n {
    // SwiftPM's module bundle also works in tests and command-line builds.
    // The app packager copies it into Contents/Resources for distribution.
    static let bundle = Bundle.module
    static var language: String { bundle.preferredLocalizations.first ?? "en" }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
