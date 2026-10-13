import SwiftUI

/// Applies the language chosen in Settings to a view and everything inside it.
///
/// SwiftUI looks strings up through the locale in its environment, so putting
/// the chosen language there changes `Text`, `Button`, `Toggle` and the rest
/// without a restart. It follows `AppSettings.language`, so a change in the
/// picker redraws every window.
struct AppLanguage: ViewModifier {
    @ObservedObject private var settings = AppSettings.shared

    func body(content: Content) -> some View {
        content.environment(\.locale, settings.locale)
    }
}

extension View {
    /// Show this view, and its children, in the app's chosen language.
    func appLanguage() -> some View { modifier(AppLanguage()) }
}

/// Strings for code that cannot use the SwiftUI environment: AppKit panels and
/// anything that needs a plain `String`.
///
/// `String(localized:)` on its own follows the language the process started
/// with, not the one chosen in Settings, so it is not used in the app. This
/// does the same lookup with the chosen language's locale.
enum L10n {
    @MainActor
    static func string(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = AppSettings.shared.locale
        return String(localized: resource)
    }

    /// What went wrong, in the chosen language: an error's own message when it
    /// has one, with the reasons added when a mix could open no output.
    ///
    /// The result is plain text, so it keeps the language it was made in; a
    /// status line that embeds it changes language the next time it is set.
    @MainActor
    static func describe(_ error: Error) -> String {
        var text = string(userMessage(for: error))
        if let start = error as? Mixer.StartError, case .noUsableOutput(let reasons) = start {
            text += ": " + reasons.map { string($0) }.joined(separator: "; ")
        }
        return text
    }
}
