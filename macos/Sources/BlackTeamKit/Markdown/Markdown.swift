import Foundation

// Turns a model's Markdown reply into a small tree the interface can draw.
// Nothing here produces markup: the tree holds only text, so a reply can never inject any.

public indirect enum MarkdownInline: Equatable {
    case text(String)
    case code(String)
    case strong([MarkdownInline])
    case em([MarkdownInline])
    case strike([MarkdownInline])
    case link(text: String, href: String)

    /// The words with all formatting removed.
    public var plain: String {
        switch self {
        case .text(let t), .code(let t): return t
        case .strong(let c), .em(let c), .strike(let c): return c.map(\.plain).joined()
        case .link(let t, _): return t
        }
    }
}

public struct MarkdownListItem: Equatable {
    public var children: [MarkdownInline]
    public var list: MarkdownList?
}

public struct MarkdownList: Equatable {
    public var ordered: Bool
    public var start: Int
    public var items: [MarkdownListItem]
}

public indirect enum MarkdownBlock: Equatable {
    case paragraph([MarkdownInline])
    case heading(level: Int, children: [MarkdownInline])
    case code(lang: String, text: String)
    case rule
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(head: [[MarkdownInline]], rows: [[[MarkdownInline]]])
}

public extension Array where Element == MarkdownInline {
    var plain: String { map(\.plain).joined() }
}

public enum Markdown {
    private static func re(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static let fence = re(#"^ {0,3}(```+|~~~+)\s*([A-Za-z0-9_+#.-]*)\s*$"#)
    private static let heading = re(#"^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$"#)
    private static let rule = re(#"^ {0,3}([-*_])(?:\s*\1){2,}\s*$"#)
    private static let item = re(#"^(\s*)(?:([-*+])|(\d{1,9})[.)])\s+(.*)$"#)
    private static let quote = re(#"^ {0,3}>\s?(.*)$"#)
    private static let divider = re(#"^\s*\|?\s*:?-{1,}:?\s*(?:\|\s*:?-{1,}:?\s*)*\|?\s*$"#)
    private static let inlinePattern = re(
        #"(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)|\*\*(?=\S)([\s\S]+?\S)\*\*|__(?=\S)([\s\S]+?\S)__(?![A-Za-z0-9_])|~~(?=\S)([\s\S]+?\S)~~|\*(?=[^\s*])([^*]*?[^\s*])\*(?!\*)|(?<![A-Za-z0-9_])_(?=[^\s_])([^_]*?[^\s_])_(?![A-Za-z0-9_])|\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)"#)

    private static func match(_ regex: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    private static func group(_ m: NSTextCheckingResult, _ n: Int, in s: String) -> String? {
        let r = m.range(at: n)
        return r.location == NSNotFound ? nil : (s as NSString).substring(with: r)
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Table cells; an escaped pipe stays inside its cell.
    private static func cells(_ line: String) -> [String] {
        var t = trim(line)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        var out: [String] = []
        var current = ""
        var previous: Character?
        for ch in t {
            if ch == "|" && previous != "\\" { out.append(current); current = "" } else { current.append(ch) }
            previous = ch
        }
        out.append(current)
        return out.map { trim($0).replacingOccurrences(of: "\\|", with: "|") }
    }

    private struct Entry {
        var indent: Int
        var ordered: Bool
        var number: Int
        var text: String
    }

    private static func nest(_ entries: [Entry], depth: Int = 0) -> MarkdownList {
        var list = MarkdownList(ordered: entries[0].ordered, start: entries[0].number, items: [])
        let base = entries[0].indent
        var deeper: [Entry] = []
        func close() {
            if !deeper.isEmpty { list.items[list.items.count - 1].list = nest(deeper, depth: depth + 1) }
            deeper = []
        }
        for entry in entries {
            if !list.items.isEmpty && entry.indent > base + 1 && depth < 4 { deeper.append(entry) }
            else { close(); list.items.append(MarkdownListItem(children: inline(entry.text), list: nil)) }
        }
        close()
        return list
    }

    public static func inline(_ text: String) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var rest = text
        while !rest.isEmpty {
            guard let found = match(inlinePattern, rest) else { break }
            let ns = rest as NSString
            if found.range.location > 0 { out.append(.text(ns.substring(to: found.range.location))) }
            if let code = group(found, 2, in: rest), group(found, 1, in: rest) != nil {
                let trimmed = trim(code)
                out.append(.code(trimmed.isEmpty ? code : trimmed))
            } else if let s = group(found, 3, in: rest) ?? group(found, 4, in: rest) {
                out.append(.strong(inline(s)))
            } else if let s = group(found, 5, in: rest) {
                out.append(.strike(inline(s)))
            } else if let s = group(found, 6, in: rest) ?? group(found, 7, in: rest) {
                out.append(.em(inline(s)))
            } else {
                out.append(.link(text: group(found, 8, in: rest) ?? "", href: group(found, 9, in: rest) ?? ""))
            }
            rest = ns.substring(from: found.range.location + found.range.length)
        }
        if !rest.isEmpty { out.append(.text(rest)) }
        return out
    }

    public static func parse(_ source: String?) -> [MarkdownBlock] {
        let lines = (source ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(inline(para.joined(separator: "\n")))) }
            para = []
        }
        var i = 0
        while i < lines.count {
            defer { i += 1 }
            let line = lines[i]
            if let f = match(fence, line) {
                // A fence with no closing line is a reply still being written: show what has arrived.
                flush()
                let marker = group(f, 1, in: line) ?? "```"
                let lang = group(f, 2, in: line) ?? ""
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let t = trim(lines[i])
                    if t.hasPrefix(marker) && !t.isEmpty && t.allSatisfy({ $0 == "`" || $0 == "~" }) { break }
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.code(lang: lang, text: body.joined(separator: "\n")))
                continue
            }
            if trim(line).isEmpty { flush(); continue }
            if let h = match(heading, line) {
                flush()
                blocks.append(.heading(level: (group(h, 1, in: line) ?? "#").count, children: inline(group(h, 2, in: line) ?? "")))
                continue
            }
            if match(rule, line) != nil { flush(); blocks.append(.rule); continue }
            if line.contains("|"), i + 1 < lines.count, lines[i + 1].contains("-"), match(divider, lines[i + 1]) != nil,
               cells(line).count == cells(lines[i + 1]).count {
                flush()
                let head = cells(line)
                var rows: [[[MarkdownInline]]] = []
                i += 2
                while i < lines.count && !trim(lines[i]).isEmpty && lines[i].contains("|") {
                    let row = cells(lines[i])
                    rows.append(head.indices.map { inline($0 < row.count ? row[$0] : "") })
                    i += 1
                }
                i -= 1
                blocks.append(.table(head: head.map(inline), rows: rows))
                continue
            }
            if match(item, line) != nil {
                flush()
                var entries: [Entry] = []
                while i < lines.count {
                    let l = lines[i]
                    if let next = match(item, l) {
                        let indent = (group(next, 1, in: l) ?? "").replacingOccurrences(of: "\t", with: "    ").count
                        let ordered = group(next, 3, in: l) != nil
                        if entries.isEmpty || indent > entries[0].indent + 1 || ordered == entries[0].ordered {
                            entries.append(Entry(indent: indent, ordered: ordered, number: Int(group(next, 3, in: l) ?? "") ?? 1, text: group(next, 4, in: l) ?? ""))
                            i += 1
                            continue
                        }
                    } else if !entries.isEmpty, !trim(l).isEmpty, l.first?.isWhitespace == true, match(fence, l) == nil {
                        // Wrapped lines belong to the item above them.
                        entries[entries.count - 1].text += "\n" + trim(l)
                        i += 1
                        continue
                    }
                    break
                }
                i -= 1
                blocks.append(.list(nest(entries)))
                continue
            }
            if match(quote, line) != nil {
                flush()
                var body: [String] = []
                while i < lines.count, let q = match(quote, lines[i]) {
                    body.append(group(q, 1, in: lines[i]) ?? "")
                    i += 1
                }
                i -= 1
                blocks.append(.quote(parse(body.joined(separator: "\n"))))
                continue
            }
            para.append(line)
        }
        flush()
        return blocks
    }
}
