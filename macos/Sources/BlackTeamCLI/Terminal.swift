import Foundation
import BlackTeamTerminal
#if canImport(Darwin)
import Darwin
#else
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif
#endif

// Terminal input and output: raw mode, the terminal being put back however the program ends, and reading keys.

func isTerminal(_ fd: Int32) -> Bool { isatty(fd) == 1 }

/// Writes to the terminal at once (no buffering surprises between our text and the terminal's).
func emit(_ text: String) {
    fputs(text, stdout)
    fflush(stdout)
}

func emitError(_ text: String) {
    fputs(text, stderr)
    fflush(stderr)
}

enum Terminal {
    fileprivate static var original = termios()
    fileprivate static var raw = false

    static var columns: Int {
        var size = winsize()
        if ioctl(1, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        if let c = ProcessInfo.processInfo.environment["COLUMNS"].flatMap({ Int($0) }), c > 0 { return c }
        return 80
    }

    /// Keys arrive one at a time with no echo; bracketed paste is switched on so a paste is not typed. Returns false if this is no terminal.
    @discardableResult
    static func enterRaw() -> Bool {
        if raw { return true }
        guard isTerminal(0), tcgetattr(0, &original) == 0 else { return false }
        var changed = original
        changed.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
        changed.c_iflag &= ~tcflag_t(IXON | ICRNL | INLCR | IGNCR | ISTRIP)
        withUnsafeMutablePointer(to: &changed.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { $0[Int(VMIN)] = 1; $0[Int(VTIME)] = 0 }
        }
        guard tcsetattr(0, TCSADRAIN, &changed) == 0 else { return false }
        raw = true
        if isTerminal(1) { emit("\u{1B}[?2004h") }
        return true
    }

    static func leaveRaw() {
        guard raw else { return }
        raw = false
        if isTerminal(1) { emit("\u{1B}[?2004l") }
        tcsetattr(0, TCSADRAIN, &original)
    }

    /// Put the terminal back if the program is stopped by a crash or a signal. Only calls that are safe inside a signal handler.
    static func installSafetyNet() {
        atexit { Terminal.leaveRaw() }
        for number in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP] {
            signal(number) { number in
                if Terminal.raw {
                    var back = Terminal.original
                    tcsetattr(0, TCSANOW, &back)
                    let off: [UInt8] = Array("\u{1B}[?2004l".utf8)
                    _ = write(1, off, off.count)
                }
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }

    /// Bytes waiting on standard input: nil when nothing came within the time, empty at end of input.
    static func readBytes(timeoutMs: Int32) -> [UInt8]? {
        var descriptor = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, timeoutMs)
        if ready < 0 { return errno == EINTR ? nil : [] }
        if ready == 0 { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(0, &buffer, buffer.count)
        if count < 0 { return errno == EINTR || errno == EAGAIN ? nil : [] }
        return Array(buffer.prefix(count))
    }
}

enum ReadResult: Equatable {
    case line(String)
    case eof
    /// Ctrl-C; `hadText` says whether something was typed (which is then thrown away).
    case interrupt(hadText: Bool)
}

/// Reads what the person types. On a terminal it is a line editor; on a pipe it is plain lines with no escape codes.
final class LineReader {
    let interactive: Bool
    var history: InputHistory
    private let historyPath: String?
    private var pendingStdin: [String] = []

    init(interactive: Bool, historyPath: String?) {
        self.interactive = interactive
        self.historyPath = historyPath
        history = interactive ? (historyPath.map { InputHistory.load(path: $0) } ?? InputHistory()) : InputHistory()
    }

    func remember(_ line: String) {
        history.add(line)
        if interactive, let historyPath { history.save(path: historyPath) }
    }

    /// `prompt` is what to draw (it may hold colour codes); `plain` is the same without them, to measure it.
    func read(prompt: String, plain: String, keepHistory: Bool = true, tab: Bool = true, question: Bool = false) -> ReadResult {
        guard interactive else {
            if isTerminal(1) || question { emit(plain) }
            guard let line = readLine(strippingNewline: true) else { return .eof }
            return .line(line)
        }
        guard Terminal.enterRaw() else {
            guard let line = readLine(strippingNewline: true) else { return .eof }
            return .line(line)
        }
        defer { Terminal.leaveRaw() }
        var buffer = LineBuffer()
        var decoder = KeyDecoder()
        let promptWidth = DisplayWidth.of(plain)
        func redraw() {
            let drawn = buffer.render(promptWidth: promptWidth, columns: Terminal.columns)
            var out = "\r\u{1B}[2K" + prompt + drawn.text + "\r"
            if drawn.cursorColumn > 0 { out += "\u{1B}[\(drawn.cursorColumn)C" }
            emit(out)
        }
        redraw()
        while true {
            guard let bytes = Terminal.readBytes(timeoutMs: decoder.isMidSequence ? 40 : -1) else {
                for key in decoder.flush() where key == .escape { _ = key }
                continue
            }
            if bytes.isEmpty { emit("\r\n"); return .eof }
            for key in decoder.feed(bytes) {
                switch key {
                case .text(let s), .paste(let s): buffer.insert(s)
                case .enter:
                    emit("\r\n")
                    if keepHistory { history.resetPosition() }
                    return .line(buffer.text)
                case .tab:
                    if tab, let completed = Slash.complete(buffer.text) { buffer.set(completed) }
                case .backspace: buffer.backspace()
                case .delete: buffer.deleteForward()
                case .left: buffer.moveLeft()
                case .right: buffer.moveRight()
                case .home: buffer.home()
                case .end: buffer.end()
                case .killToStart: buffer.killToStart()
                case .killToEnd: buffer.killToEnd()
                case .deleteWord: buffer.deleteWord()
                case .up: if keepHistory, let line = history.previous(current: buffer.text) { buffer.set(line) }
                case .down: if keepHistory, let line = history.next() { buffer.set(line) }
                case .clear: emit("\u{1B}[2J\u{1B}[H")
                case .eof:
                    if buffer.isEmpty { emit("\r\n"); return .eof }
                    buffer.deleteForward()
                case .interrupt:
                    emit("^C\r\n")
                    return .interrupt(hadText: !buffer.isEmpty)
                case .escape: break
                }
            }
            redraw()
        }
    }
}
