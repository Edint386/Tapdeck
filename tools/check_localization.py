#!/usr/bin/env python3
"""Checks that the String Catalog and the sources agree. Run by build.sh.

    tools/check_localization.py <directory of .stringsdata files>

The compiler lists every string the code asks to have translated, in one
.stringsdata file per source file (swiftc -emit-localized-strings). This compares
that list with Resources/Localizable.xcstrings and fails the build on:

  * a string in the code that is missing from the catalog, or a catalog entry
    nothing uses any more
  * an entry without a translated English, Japanese and Simplified Chinese value
  * a translated value identical to the English one, unless the entry's comment says
    "Same in every language" (an untranslated string looks exactly like that)
  * placeholders (%@, %lld, ...) that differ from the English ones
  * Japanese written with 、 or 。 instead of the full-width ， and ．
  * Simplified Chinese containing kana (left over from the Japanese), the Japanese ．,
    or half-width , . ; : ! ? next to Chinese text instead of ，。；：！？
  * the ways of getting a string that would ignore the language chosen in the app:
    String(localized:) or NSLocalizedString in the app layer, and a view helper that
    takes its title as a String, which reaches Text or .help verbatim

and checks that Info.plist's permission descriptions are translated too.
"""
import glob
import json
import re
import sys

LANGUAGES = ("en", "ja", "zh-Hans")
TRANSLATIONS = LANGUAGES[1:]
SAME = "Same in every language"
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|lf|ld|d|f|@)")
KANA = re.compile(r"[\u3040-\u30ff]")
HAN = r"[\u4e00-\u9fff]"
# Half-width punctuation touching a Chinese character. A full stop only counts after
# one, so "1.5" and "Tapdeck.app" stay allowed.
HALF_WIDTH_BESIDE_HAN = re.compile(rf"{HAN}[,.;:!?]|[,;:!?]{HAN}")

errors = []


def fail(message):
    errors.append(message)


def placeholders(text):
    # Positional markers (%1$lld) only say where an argument goes; what matters
    # here is which arguments there are.
    return sorted(re.sub(r"%\d+\$", "%", m) for m in PLACEHOLDER.findall(text))


def check_catalog(path, used=None):
    catalog = json.load(open(path, encoding="utf-8"))
    strings = catalog["strings"]
    if used is not None:
        for key in sorted(used - set(strings)):
            fail(f"{path}: used in the code but missing: {key!r}")
        for key in sorted(set(strings) - used):
            fail(f"{path}: no longer used in the code: {key!r}")

    for key, entry in strings.items():
        localizations = entry.get("localizations", {})
        values = {}
        for language in LANGUAGES:
            unit = localizations.get(language, {}).get("stringUnit")
            if not unit or not unit.get("value", "").strip():
                fail(f"{path}: {key!r} has no {language} value")
                continue
            if unit.get("state") != "translated":
                fail(f"{path}: {key!r} is {unit.get('state')!r} in {language}, not translated")
            values[language] = unit["value"]
        if len(values) < len(LANGUAGES):
            continue
        for language in TRANSLATIONS:
            if values[language] == values["en"] and SAME not in entry.get("comment", ""):
                fail(f"{path}: {key!r} is the same in {language} as in English; translate it, "
                     f"or comment {SAME!r}")
            if placeholders(values["en"]) != placeholders(values[language]):
                fail(f"{path}: {key!r} has different placeholders in English and {language}")
        if "、" in values["ja"] or "。" in values["ja"]:
            fail(f"{path}: {key!r} uses 、 or 。; use the full-width ， and ．")
        chinese = values["zh-Hans"]
        if KANA.search(chinese):
            fail(f"{path}: {key!r} has kana in Simplified Chinese")
        if "．" in chinese:
            fail(f"{path}: {key!r} uses the Japanese ． in Simplified Chinese; use 。")
        if HALF_WIDTH_BESIDE_HAN.search(chinese):
            fail(f"{path}: {key!r} has half-width punctuation beside Chinese text; use ，。；：！？")
    return strings


def used_keys(directory):
    used = set()
    files = glob.glob(f"{directory}/*.stringsdata")
    if not files:
        fail(f"no .stringsdata files in {directory}; was the app compiled with -emit-localized-strings?")
    for path in files:
        data = json.load(open(path, encoding="utf-8"))
        for table, entries in data.get("tables", {}).items():
            if table != "Localizable":
                fail(f"{path}: strings for table {table!r}; only Localizable is compiled")
            for entry in entries:
                # Empty and whitespace-only strings are layout placeholders.
                if entry["key"].strip():
                    used.add(entry["key"])
    return used


def check_sources():
    # A helper like section(_ title: String) passes the text on to Text(title), the verbatim
    # initializer, so it is shown in English whatever language is chosen. Its parameter has to be
    # a LocalizedStringKey (or a LocalizedStringResource) for the literal at the call site to
    # be extracted and translated.
    helper = re.compile(r'\bfunc \w+(?:<[^>]*>)?\(_ (?:title|text|label|help|caption|hint|message): String\b')
    for path in sorted(glob.glob("Sources/App/*.swift")):
        for number, line in enumerate(open(path, encoding="utf-8"), 1):
            code = line.split("//")[0]
            where = f"{path}:{number}"
            if not path.endswith("LanguageEnvironment.swift") and re.search(r"String\(localized:|NSLocalizedString", code):
                fail(f"{where}: String(localized:) follows the process language, not the choice made in the "
                     "app; use a LocalizedStringResource with L10n.string, or Text")
            if helper.search(code):
                fail(f"{where}: a String parameter reaches Text or .help as is and is never translated; "
                     "take a LocalizedStringKey")


def check_info_plist(strings):
    for key in ("NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription"):
        if key not in strings:
            fail(f"Resources/InfoPlist.xcstrings: {key} is not translated")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    check_catalog("Resources/Localizable.xcstrings", used_keys(sys.argv[1]))
    check_info_plist(check_catalog("Resources/InfoPlist.xcstrings"))
    check_sources()
    if errors:
        print("Localization check failed:", file=sys.stderr)
        for message in errors:
            print("  " + message, file=sys.stderr)
        sys.exit(1)
    print("Localization check passed.")
