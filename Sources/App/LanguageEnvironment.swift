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
}
