import SwiftUI
import AppKit

/// The message box. Return sends, Shift-Return makes a new line; text being composed in an input method is left alone.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool
    let theme: Theme
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        if view.string != text && !view.hasMarkedText() { view.string = text }
        view.isEditable = enabled
        view.isSelectable = true
        // 13 point text on a 1.7 line, as `.composer textarea` sets it.
        let font = NSFont(name: "AdwaitaSans-Regular", size: 13) ?? .systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 13 * 1.7; paragraph.maximumLineHeight = 13 * 1.7
        view.font = font
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor(theme.ink)]
        view.textColor = NSColor(theme.ink)
        view.insertionPointColor = NSColor(theme.accent)
        view.placeholder = placeholder
        view.placeholderColor = NSColor(theme.faint)
        view.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if textView.hasMarkedText() { return false }
            if NSEvent.modifierFlags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }
    }
}

final class ComposerTextView: NSTextView {
    var placeholder = ""
    var placeholderColor = NSColor.secondaryLabelColor
    private var focused = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: placeholderColor, .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default]
        let inset = textContainerInset
        (placeholder as NSString).draw(at: NSPoint(x: inset.width + (textContainer?.lineFragmentPadding ?? 0), y: inset.height), withAttributes: attributes)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !focused, let window else { return }
        focused = true
        DispatchQueue.main.async { if self.isEditable { window.makeFirstResponder(self) } }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// Tells whether the person has scrolled up from the newest text, so streaming text only follows them when they have not.
struct ScrollPinTracker: NSViewRepresentable {
    @Binding var pinned: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.find(from: view, attempts: 8)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.parent = self }

    final class Coordinator {
        var parent: ScrollPinTracker
        private var observer: NSObjectProtocol?
        init(_ parent: ScrollPinTracker) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func find(from view: NSView, attempts: Int) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                if let scroll = view.enclosingScrollView { self.watch(scroll) }
                else if attempts > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.find(from: view, attempts: attempts - 1) } }
            }
        }

        private func watch(_ scroll: NSScrollView) {
            // Only the person's own scrolling posts this, so the app's own scrolling to the end never unpins.
            observer = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self, weak scroll] _ in
                guard let self, let scroll, let document = scroll.documentView else { return }
                let atEnd = scroll.contentView.bounds.maxY >= document.frame.height - 48
                if self.parent.pinned != atEnd { self.parent.pinned = atEnd }
            }
        }
    }
}
