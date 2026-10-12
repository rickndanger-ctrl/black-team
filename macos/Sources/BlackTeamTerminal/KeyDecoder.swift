import Foundation

/// One thing the person did at the keyboard.
public enum Key: Equatable {
    case text(String)
    case paste(String)
    case enter, tab, backspace, delete
    case left, right, up, down, home, end
    case killToStart, killToEnd, deleteWord
    case eof, interrupt, clear, escape
}

/// Turns the bytes a terminal sends into keys. Feed it whatever has arrived; a key may be split across feeds.
/// UTF-8 is assembled before it is passed on, and a bracketed paste (ESC [ 200 ~ ... ESC [ 201 ~) arrives as one `.paste`.
public struct KeyDecoder {
    private enum State { case ground, escape, csi, ss3, paste }
    private var state = State.ground
    private var params: [UInt8] = []
    private var pending: [UInt8] = []
    private var expected = 0
    private var pasted: [UInt8] = []
    private var tail: [UInt8] = []

    public init() {}

    /// A lone escape key looks like the start of a sequence until nothing follows; call this when input has gone quiet.
    public mutating func flush() -> [Key] {
        defer { state = .ground; params = []; pending = []; expected = 0 }
        return state == .escape ? [.escape] : []
    }

    public var isMidSequence: Bool { state != .ground || !pending.isEmpty }

    public mutating func feed(_ bytes: [UInt8]) -> [Key] {
        var keys: [Key] = []
        for byte in bytes { step(byte, &keys) }
        return keys
    }

    private mutating func step(_ byte: UInt8, _ keys: inout [Key]) {
        switch state {
        case .paste:
            pasted.append(byte)
            let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
            if pasted.count >= end.count, Array(pasted.suffix(end.count)) == end {
                pasted.removeLast(end.count)
                keys.append(.paste(String(decoding: pasted, as: UTF8.self)))
                pasted = []; state = .ground
            }
        case .escape:
            if byte == 0x5B { state = .csi; params = [] }
            else if byte == 0x4F { state = .ss3 }
            else { state = .ground } // Alt+key: ignored
        case .ss3:
            state = .ground
            switch byte {
            case 0x41: keys.append(.up)
            case 0x42: keys.append(.down)
            case 0x43: keys.append(.right)
            case 0x44: keys.append(.left)
            case 0x48: keys.append(.home)
            case 0x46: keys.append(.end)
            default: break
            }
        case .csi:
            if byte >= 0x30 && byte <= 0x3F { params.append(byte); if params.count > 16 { state = .ground }; return }
            if byte >= 0x20 && byte <= 0x2F { return }
            state = .ground
            let number = Int(String(decoding: params.prefix { $0 != 0x3B }, as: UTF8.self)) ?? 0
            switch byte {
            case 0x41: keys.append(.up)
            case 0x42: keys.append(.down)
            case 0x43: keys.append(.right)
            case 0x44: keys.append(.left)
            case 0x48: keys.append(.home)
            case 0x46: keys.append(.end)
            case 0x7E:
                switch number {
                case 1, 7: keys.append(.home)
                case 4, 8: keys.append(.end)
                case 3: keys.append(.delete)
                case 200: state = .paste; pasted = []
                default: break
                }
            default: break
            }
        case .ground:
            if expected > 0 {
                if byte & 0xC0 == 0x80 {
                    pending.append(byte)
                    if pending.count == expected {
                        keys.append(.text(String(decoding: pending, as: UTF8.self))); pending = []; expected = 0
                    }
                    return
                }
                pending = []; expected = 0 // a broken character: drop it and read this byte afresh
            }
            switch byte {
            case 0x1B: state = .escape
            case 0x0D, 0x0A: keys.append(.enter)
            case 0x09: keys.append(.tab)
            case 0x7F, 0x08: keys.append(.backspace)
            case 0x01: keys.append(.home)
            case 0x05: keys.append(.end)
            case 0x02: keys.append(.left)
            case 0x06: keys.append(.right)
            case 0x10: keys.append(.up)
            case 0x0E: keys.append(.down)
            case 0x15: keys.append(.killToStart)
            case 0x0B: keys.append(.killToEnd)
            case 0x17: keys.append(.deleteWord)
            case 0x04: keys.append(.eof)
            case 0x03: keys.append(.interrupt)
            case 0x0C: keys.append(.clear)
            case 0x20...0x7E: keys.append(.text(String(UnicodeScalar(byte))))
            case 0xC2...0xDF: pending = [byte]; expected = 2
            case 0xE0...0xEF: pending = [byte]; expected = 3
            case 0xF0...0xF4: pending = [byte]; expected = 4
            default: break
            }
        }
    }
}
