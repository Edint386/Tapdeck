import Foundation

/// What the user chose for the app's language.
enum LanguageChoice: String, CaseIterable, Identifiable, Sendable {
    /// Follow the system's language list, or the per-app language set in
    /// System Settings.
    case system
    case en
    case ja

    var id: String { rawValue }
}

/// The languages Tapdeck is translated into, and how a choice becomes one of
/// them.
///
/// Kept free of any UI framework so it can be tested without the app.
enum Localization {
    /// Languages with a translation, as bundle localization codes.
    static let available = ["en", "ja"]

    /// Shown when nothing in the system's list is available.
    static let fallback = "en"

    /// The language code the app should be shown in.
    ///
    /// A chosen language is used as it is. For `system`, the first language in
    /// the system's list that Tapdeck has strings for wins, matched on the
    /// language part only (`ja-JP`, `ja_JP` and `JA` are all Japanese). With
    /// no match the app is shown in English.
    static func resolve(_ choice: LanguageChoice, systemPreferred: [String]) -> String {
        switch choice {
        case .en: return "en"
        case .ja: return "ja"
        case .system:
            for tag in systemPreferred {
                let code = tag.split(whereSeparator: { $0 == "-" || $0 == "_" })
                    .first.map { $0.lowercased() } ?? ""
                if available.contains(code) { return code }
            }
            return fallback
        }
    }

    /// The languages the system lists for this app, read now.
    ///
    /// `AppleLanguages` in Tapdeck's own preferences is the language set for
    /// this app, either in System Settings or by Tapdeck itself; without it the
    /// system-wide list applies. Read live rather than from the process's
    /// launch-time state, so a change made while the app runs is seen.
    static func currentSystemPreferred() -> [String] {
        let stored = CFPreferencesCopyAppValue("AppleLanguages" as CFString,
                                               kCFPreferencesCurrentApplication)
        return (stored as? [String]) ?? Locale.preferredLanguages
    }
}

/// An error that can describe itself in the app's language.
///
/// The engine produces the wording; the app decides the language it is shown
/// in. `errorDescription` stays available for the command line harness, which
/// shows the system's default language.
protocol MessageError: Error {
    var message: LocalizedStringResource { get }
}

/// What to tell the user about an error: the error's own message when it has
/// one, otherwise the system's text for it, which keeps the language it was
/// produced in.
func userMessage(for error: Error) -> LocalizedStringResource {
    if let known = error as? MessageError { return known.message }
    return "\(error.localizedDescription)"
}
