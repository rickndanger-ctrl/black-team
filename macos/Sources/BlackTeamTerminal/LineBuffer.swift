import Foundation

/// The text being typed and where the cursor is. The cursor counts whole characters, so an edit never leaves half of one.
public struct LineBuffer: Equatable {
    public private(set) var characters: [Character]
    public private(set) var cursor: Int

    public init(_ text: String = "") {
        characters = Array(LineBuffer.normalized(text))
        cursor = characters.count
    }

    public var text: String { String(characters) }
    public var isEmpty: Bool { characters.isEmpty }
    public var count: Int { characters.count }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public mutating func set(_ text: String) {
        characters = Array(LineBuffer.normalized(text)); cursor = characters.count
    }

    public mutating func clear() { characters = []; cursor = 0 }

    /// Types text at the cursor. Marks that combine with the character before them join it.
    public mutating func insert(_ text: String) {
        let added = LineBuffer.normalized(text).unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }
        if added.isEmpty { return }
        let head = String(characters[..<cursor]) + String(String.UnicodeScalarView(added))
        let headCharacters = Array(head)
        characters = headCharacters + Array(characters[cursor...])
        cursor = headCharacters.count
    }

    public mutating func moveLeft() { if cursor > 0 { cursor -= 1 } }
    public mutating func moveRight() { if cursor < characters.count { cursor += 1 } }
    public mutating func home() { cursor = 0 }
    public mutating func end() { cursor = characters.count }

    public mutating func backspace() {
        guard cursor > 0 else { return }
        characters.remove(at: cursor - 1); cursor -= 1
    }

    public mutating func deleteForward() {
        guard cursor < characters.count else { return }
        characters.remove(at: cursor)
    }

    /// Ctrl-U: everything before the cursor.
    public mutating func killToStart() { characters.removeSubrange(0..<cursor); cursor = 0 }
    /// Ctrl-K: everything after the cursor.
    public mutating func killToEnd() { characters.removeSubrange(cursor...) }

    /// Ctrl-W: the word before the cursor, and the spaces between it and the cursor.
    public mutating func deleteWord() {
        var start = cursor
        while start > 0, characters[start - 1].isWhitespace { start -= 1 }
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        characters.removeSubrange(start..<cursor); cursor = start
    }

    // MARK: Drawing

    /// What to draw on a line of `columns` columns after a prompt that is `promptWidth` wide, and the column (counted from the
    /// start of the line) where the cursor goes. A line break in the text is drawn as a return mark; a line too long to fit
    /// scrolls so the cursor stays in view.
    public func render(promptWidth: Int, columns: Int) -> (text: String, cursorColumn: Int) {
        let shown = characters.map { c -> Character in c == "\n" ? "\u{21B5}" : (c == "\t" ? " " : c) }
        let room = max(4, columns - promptWidth - 1)
        let widths = shown.map { DisplayWidth.of($0) }
        let total = widths.reduce(0, +)
        var start = 0, end = shown.count
        if total > room {
            var used = 0
            start = cursor
            while start > 0, used + widths[start - 1] <= room / 2 { start -= 1; used += widths[start] }
            end = cursor
            var span = used
            while end < shown.count, span + widths[end] <= room { span += widths[end]; end += 1 }
            while start > 0, span + widths[start - 1] <= room { start -= 1; span += widths[start] }
        }
        let text = String(shown[start..<end])
        let before = widths[start..<cursor].reduce(0, +)
        return (text, promptWidth + before)
    }
}
