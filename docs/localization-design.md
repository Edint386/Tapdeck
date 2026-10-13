# In-app language choice — design proposal

Status: proposal only. Nothing in the app has been changed. Measurements below were made on
macOS 26.6 (25G72) with Xcode's toolchain, using a throwaway app built the way Tapdeck is built (swiftc, a
SwiftUI window, a hand-made `.app` bundle, a String Catalog compiled by `xcstringstool`).

## What is wanted

Settings offers **System default / English / 日本語**. The choice applies inside the app
without a restart wherever that is possible. Tapdeck has no localization today: every string is
English and hard-coded, so the system language currently has no effect on it.

## Recommendation

1. **Switch our own text live, through SwiftUI's locale.** Inject `.environment(\.locale, …)`
   at the three SwiftUI roots (main window, Settings scene, menu bar popover) from one
   `AppSettings.language` value.
2. **Hold model-layer messages as `LocalizedStringKey`**, not `String`, so they re-render
   after a switch. The 43 `status = "…"` lines keep their wording.
3. **Never call `String(localized:)` without a `bundle:`** in app code; it follows the process
   language, not the choice made in the app. Strings built in AppKit code use one helper that
   reads the chosen language's bundle.
4. **Leave system-supplied pieces to the next launch**: the app menu, the Settings window's own
   title, file dialogs and the permission prompts follow the process language. Store the choice
   in `AppleLanguages` of Tapdeck's own defaults so the next launch matches. No automatic
   restart: quitting stops every running mix.
5. Build with the same pipeline SpellBar already uses: `Resources/Localizable.xcstrings`
   (explicit `en` and `ja` values), `xcstringstool compile` into the app's Resources, and a
   check script that fails the build on a missing or mismatched translation.

## What was measured

One throwaway window showed the same word obtained six ways. Screenshots are of that app's own
window only.

| | How the text is produced | System English, then switched to 日本語 while running | System 日本語 (launch override), in-app English |
|---|---|---|---|
| A | `Text("Start")` | changed to 開始 | stayed English |
| B | `Button("Settings…")` | changed to 設定… | stayed English |
| C | `Text(String(localized: "Start"))` | **stayed English** | showed 開始 (follows the process) |
| D | `String(localized:, bundle: chosen)` | changed | stayed English |
| E | D with interpolation and reordered arguments | changed (`3 / 4 を録音中`) | stayed English |
| F | a `LocalizedStringKey` value created once, rendered later | changed | not run |

Also observed:

- With the process language 日本語, the system-supplied app menu was Japanese (Expについて,
  Expを非表示, Expを終了) although the in-app choice was English.
- Writing `AppleLanguages = (ja)` into the app's own defaults domain made a plain relaunch
  report `Bundle.main.preferredLocalizations` as `ja`. The key was removed afterwards.
- `xcstringstool compile` produced `en.lproj` only when the catalog has explicit `en` values;
  with `ja` values alone it produced just `ja.lproj`.
- SpellBar already builds this way (`build.sh`, `tools/check_localization.py`).

## Not measured (inference — to confirm while implementing)

- Whether the Settings scene's and the main window's own titles follow the locale environment.
- `.help(…)` tooltips, `Menu(…)` and `Section(…)` titles inside the popover (expected to
  behave like A and B, because they take `LocalizedStringKey`).
- That file dialogs and permission prompts follow the process language only.
- Whether System Settings › Applications › Tapdeck (the per-app language) and the in-app choice
  stay consistent, since both write `AppleLanguages`.
- How much wider or narrower the Japanese strings are in the Recording tab and the effects
  popover.

## Design

**Choice and resolution.** `AppSettings.language` is `system`, `en` or `ja`, stored in
UserDefaults as `settings.language` beside the other settings. `system` resolves to the first
of `Bundle.main.preferredLocalizations` (which includes a per-app language set in System
Settings), falling back to English. A pure function does the resolving so it can be tested
offline.

**Where it applies.**

| Part | Live? |
|---|---|
| SwiftUI text in the main window, Settings, popover (`Text`, `Button`, `Toggle`, `Picker`, …) | yes, via the locale environment |
| Status lines and similar model messages | yes, once held as `LocalizedStringKey` |
| Engine messages (4 error descriptions, file format titles, source kind labels) | yes after moving the wording to the app layer; the engine keeps identifiers |
| Our own AppKit strings (folder panel button, alerts) | yes, looked up with the chosen bundle when created |
| App menu, Settings window title, file dialogs, permission prompts | next launch |

The menu bar popover is hosted by an `NSHostingController` created once, so its root view is
wrapped in a small container that reads the language and applies the locale.

**Storage.** `settings.language` for the choice; `AppleLanguages` in Tapdeck's own domain for
the process language on the next launch (set for English and 日本語, removed for System default).
Settings shows one line under the picker: *The app menu and file dialogs change the next time
Tapdeck starts.*

**Scope boundaries.** The command line harness `tapproof`, the driver and the documentation stay
English. The three permission usage descriptions in `Info.plist` get `InfoPlist` translations,
which follow the process language.

## Size

A script that looks at lines using `Text(`, `Button(`, `Label(`, `status = `, `.help(` and
similar found about **293 distinct strings** (267 in `Sources/App`, 27 in `Sources/Engine`).
This is an estimate by pattern, not a count of what ends up in the catalog. Of the SwiftUI
call sites (about 180) none changes in code; they only need catalog entries. The code changes are
the `status` type, a handful of enum titles, the four engine errors, the three roots and the
settings picker.

Rough order: infrastructure and build step; model types and engine wording; the Japanese
catalog (every string, polite form); the picker and settings text; render review in both
languages; release notes. A new feature, so the next version would be 0.5.0.

## Tests

1. **Catalog check in the build** (like SpellBar's): every key used in the sources exists with
   `en` and `ja` values, placeholders match between languages, nothing is marked for review,
   and a lint rejects `String(localized:)` without `bundle:` outside the helper.
2. **Resolution function** in a `tapproof` test: for example `system` with preferences
   `["fr", "ja"]` gives `ja`; unsupported languages give `en`.
3. **Render matrix**: each main view in English and Japanese at the real window size, reviewed
   for clipping and for the layout staying put (the Recording tab's mode switch and record bar).
4. **Live switch on the installed app**: change the picker, capture the window before and
   after, as in the experiment above.
5. **Next launch**: after choosing a language, relaunch and read the app menu's item names.

## Decisions needed

- Picker in **Settings › General** only (recommended), or also in the menu bar panel.
- Japanese style: です／ます (recommended) and who reviews the translation.
- Whether to localize the permission usage descriptions in this change (recommended: yes, three
  strings).
