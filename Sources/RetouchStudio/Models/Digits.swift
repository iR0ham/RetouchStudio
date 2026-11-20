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

    /// A width × height readout. The unit is a word in the interface language;
    /// in Persian the numeric run is isolated left-to-right, because without the
    /// isolation the paragraph direction moves the unit in front of the numbers
    /// and swaps the two values ("px ۴۰۳۲ × ۲۲۶۸").
    static func pixelSize(_ width: Int, _ height: Int) -> String {
        let run = "\(num(width)) × \(num(height))"
        guard AppLanguage.current == .persian else { return "\(run) px" }
        return "\u{2066}\(run)\u{2069} پیکسل"
    }

    /// One pixel count, such as a brush diameter.
    static func pixels(_ value: Int) -> String {
        AppLanguage.current == .persian ? "\(num(value)) پیکسل" : "\(value) px"
    }

    /// Converts the Latin digits inside an already-formatted string and leaves
    /// every other character alone, so a mixed string keeps its punctuation.
    static func convert(_ text: String) -> String {
        guard AppLanguage.current == .persian else { return text }
        return persian(text)
    }

    /// The same conversion without asking the interface language, for a string
    /// that is already written in Persian (the Persian table speaks for
    /// itself, even when a test runs under the English default).
    static func persian(_ text: String) -> String {
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
