import Foundation

/// The preference is shared by the iOS app and its extensions. Watch receives it
/// over WatchConnectivity because app group defaults do not span devices.
public enum AppLanguage: String, CaseIterable {
    case automatic, polish = "pl", english = "en"

    public var title: String {
        switch self {
        case .automatic: return L10n.string("Automatic")
        case .polish: return "Polski"
        case .english: return "English"
        }
    }

    public func resolved(preferredLanguages: [String]) -> String {
        switch self {
        case .polish: return "pl"
        case .english: return "en"
        case .automatic:
            // Only the primary system language determines Automatic. Unsupported
            // systems use English even if Polish is a secondary preference.
            return preferredLanguages.first?.split(separator: "-").first?.lowercased() == "pl" ? "pl" : "en"
        }
    }
}

public extension Notification.Name {
    static let appLanguageChanged = Notification.Name("appLanguageChanged")
}

public enum L10n {
    public static let preferenceKey = "appLanguage"
    private static let defaults = UserDefaults(suiteName: "group.com.kabouzeid.Iron") ?? .standard

    public static var language: AppLanguage {
        get { AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .automatic }
        set {
            guard language != newValue else { return }
            defaults.set(newValue.rawValue, forKey: preferenceKey)
            NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
        }
    }

    public static var languageCode: String { language.resolved(preferredLanguages: Locale.preferredLanguages) }
    public static var locale: Locale { Locale(identifier: languageCode) }

    /// Explicit bundle lookup also applies the in-app preference to UIKit,
    /// notifications, Siri responses and other strings outside SwiftUI.
    public static func string(_ key: String, bundle: Bundle = .main) -> String {
        let english = bundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        let selected = bundle.path(forResource: languageCode, ofType: "lproj").flatMap(Bundle.init(path:))
        let fallback = english?.localizedString(forKey: key, value: key, table: nil) ?? key
        return selected?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}
