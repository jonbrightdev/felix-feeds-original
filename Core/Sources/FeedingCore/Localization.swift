import Foundation

public enum L10n {
    public static var languageCode: String { Bundle.module.preferredLocalizations.first ?? "en" }
    /// Explicit locales are useful for format checks; normal calls follow the app's language.
    public static func text(_ key: String, locale: Locale? = nil) -> String {
        let bundle: Bundle
        if let locale {
            let language = locale.language.languageCode?.identifier ?? "en"
            let supported = language == "de" ? "de" : "en"
            bundle = Bundle.module.url(forResource: supported, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? .module
        } else { bundle = .module }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    public static func format(_ key: String, _ arguments: CVarArg..., locale: Locale? = nil) -> String {
        String(format: text(key, locale: locale), locale: locale ?? .current, arguments: arguments)
    }
}
