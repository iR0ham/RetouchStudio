import Foundation

/// Numbers follow the language of the interface: Latin digits in English,
/// Persian-Indic digits in Persian, so a Persian screen reads as one script.
enum Digits {
    private static let persianDigits = Array("۰۱۲۳۴۵۶۷۸۹")

    static func num(_ value: Int) -> String {
        convert(String(value))
    }

    /// A percentage, written the way the language writes it.
    static func percent(_ value: Int) -> String {
        guard AppLanguage.current == .persian else { return "\(value)%" }
        return "\(num(value))٪"
    }

    /// Converts the Latin digits inside an already-formatted string and leaves
    /// every other character alone, so a mixed string keeps its punctuation.
    static func convert(_ text: String) -> String {
        guard AppLanguage.current == .persian else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if character.isASCII,
               let value = character.wholeNumberValue,
               let index = Int(exactly: value),
               persianDigits.indices.contains(index) {
                out.append(persianDigits[index])
            } else {
                out.append(character)
            }
        }
        return out
    }
}
