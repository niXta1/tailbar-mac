import Foundation

// English is the development language. Every key is the English text itself,
// so a string missing from a translation falls back to English. Translations
// live in Resources/<language>.lproj/Localizable.strings; keep their format
// specifiers (%@, %ld, %d) in the same order as in the key.

/// Localized text for `key`.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

/// Localized format string for `key`, filled in with `arguments`.
func L(format key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
