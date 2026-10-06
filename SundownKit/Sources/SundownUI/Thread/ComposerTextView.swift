import AppKit
import SwiftUI

/// What the message field asks the composer to do with a key.
enum ComposerKey {
    /// Return, or ⌘Return, with its modifiers. Sent only once an input method has committed.
    case submit(EventModifiers)
    case tab
    case up
    case down
    case escape
}

/// The message field: plain text, multiline, that styles its Markdown as it's typed
/// (`ComposerMarkdown`), one line tall to twelve, then scrolling.
///
/// AppKit, because SwiftUI's rich `TextEditor` makes every change to its text from code an
/// undoable replacement of the whole text: styling after each keystroke made Undo take the styling
/// back first and select everything (macOS 27, 2026-10-05). Here the styling is attributes on the
/// text storage, which Undo never sees, and Return arrives as the text view's own command, after an
/// input method's marked text is committed.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// The text's height, which the composer frames the field to: one line to twelve.
    @Binding var height: CGFloat
    var scale: CGFloat
    /// The composer's handling of a key; false lets the text view do its own.
    var onKey: (ComposerKey) -> Bool
    /// Told when the field gains or loses the keyboard.
    var onFocus: (Bool) -> Void
    /// Pasted content that isn't text (an image, a file), for the composer to attach.
    var onPasteOther: (NSPasteboard) -> Void
    /// Bumped to put the keyboard in the field.
    var focusRequest: Int
    /// What VoiceOver says the empty field offers: the placeholder.
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        // As wide as the clip view it starts in, which resizes it by the difference.
        let view = ComposerNSTextView(frame: .zero)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.smartInsertDeleteEnabled = false
        view.usesFindBar = false
        // Files dropped on the field go to the composer, which attaches them.
        view.unregisterDraggedTypes()
        view.setAccessibilityIdentifier("composer.input")
        view.setAccessibilityLabel("Message")
        scroll.documentView = view
        context.coordinator.view = view
        context.coordinator.set(text, scale: scale, undoable: false)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.scale != scale || coordinator.view?.string != text {
            coordinator.set(text, scale: scale)
        }
        coordinator.view?.setAccessibilityPlaceholderValue(placeholder)
        if focusRequest != coordinator.focusRequest {
            coordinator.focusRequest = focusRequest
            coordinator.view?.wantsFocus = true
            // After this update: taking the keyboard tells the composer, which updates its state.
            DispatchQueue.main.async { coordinator.view?.takeFocusIfWanted() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var view: ComposerNSTextView?
        var scale: CGFloat = 0
        var focusRequest = 0

        init(_ parent: ComposerTextView) {
            self.parent = parent
            focusRequest = parent.focusRequest
        }

        /// Text from outside the field — a draft, a completion, a message put back — with the
        /// caret after it. An edit Undo can take back, so its record of typing stays true.
        func set(_ text: String, scale: CGFloat, undoable: Bool = true) {
            guard let view else { return }
            self.scale = scale
            if view.string != text {
                let all = NSRange(location: 0, length: (view.string as NSString).length)
                if undoable, view.shouldChangeText(in: all, replacementString: text) {
                    view.textStorage?.replaceCharacters(in: all, with: text)
                    view.didChangeText()
                } else {
                    view.string = text
                }
                view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
            restyle()
            measure()
        }

        /// The text's laid-out height, told to the composer when it changes.
        func measure() {
            guard let view, let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            var used = layout.usedRect(for: container).maxY
            // The line after a final newline counts: the caret is on it.
            if !layout.extraLineFragmentRect.isEmpty { used = max(used, layout.extraLineFragmentRect.maxY) }
            let line = ComposerMarkdown.lineHeight(scale: scale)
            let height = min(max(ceil(used), line), line * 12)
            if parent.height != height {
                DispatchQueue.main.async { [parent] in parent.height = height }
            }
        }

        /// The Markdown's styles as attributes, which Undo doesn't record. Not while an input
        /// method is composing: its marked text has its own look.
        func restyle() {
            guard let view, let storage = view.textStorage, !view.hasMarkedText() else { return }
            ComposerMarkdown.apply(to: storage, scale: scale)
            view.typingAttributes = ComposerMarkdown.attributes(.init(), scale: scale)
        }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            restyle()
            measure()
            // Not while an input method is composing: what's marked isn't written yet.
            if !view.hasMarkedText(), parent.text != view.string { parent.text = view.string }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if parent.onKey(.submit(EventModifiers(flags))) { return true }
                // A new line continues the list or quote it's in, or ends an empty item.
                guard let view else { return false }
                view.apply(ComposerEditing.newLine(in: view.string, selection: view.selectedRange()))
                return true
            case #selector(NSResponder.insertTab(_:)):
                guard let view else { return false }
                // A completion or the suggested prompt first; then a list item steps in; otherwise
                // Tab moves on, as in any field, rather than typing a tab.
                if parent.onKey(.tab) { return true }
                if let edit = ComposerEditing.indent(in: view.string, selection: view.selectedRange(), outward: false) {
                    view.apply(edit)
                } else {
                    textView.window?.selectNextKeyView(nil)
                }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                guard let view else { return false }
                if let edit = ComposerEditing.indent(in: view.string, selection: view.selectedRange(), outward: true) {
                    view.apply(edit)
                } else {
                    textView.window?.selectPreviousKeyView(nil)
                }
                return true
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.cancelOperation(_:)):
                // Never the text view's own, which offers word completions.
                _ = parent.onKey(.escape)
                return true
            default: return false
            }
        }
    }
}

/// The field's text view: tells the composer when it gains and loses the keyboard, sends ⌘Return
/// as a submit, and pastes only text, handing anything else to the composer.
final class ComposerNSTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?

    /// The field takes the keyboard when its window opens or focus has nowhere else to go (a
    /// chat switched, its field replaced), never from the sidebar or search.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder === window || window.firstResponder == nil { self.wantsFocus = true }
            self.takeFocusIfWanted()
        }
    }

    /// Asked for (New Chat by name), or nothing else had it: taken once the field is in a window.
    var wantsFocus = false

    func takeFocusIfWanted() {
        guard wantsFocus, let window else { return }
        wantsFocus = false
        if window.firstResponder !== self { window.makeFirstResponder(self) }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.parent.onFocus(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.parent.onFocus(false) }
        return resigned
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // Narrower or wider, the text wraps differently.
        if widthChanged { coordinator?.measure() }
    }

    /// One edit, as one step Undo takes back.
    func apply(_ edit: ComposerEditing.Edit) {
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.text) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.text)
        didChangeText()
        breakUndoCoalescing()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    /// A pair's opening character typed over a selection wraps it, as VS Code does: `*` makes
    /// it italic, `` ` `` code, `[` the start of a link.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let selection = selectedRange()
        if let typed = string as? String, selection.length > 0, !hasMarkedText(),
           replacementRange.location == NSNotFound, let close = ComposerEditing.surroundingPairs[typed] {
            apply(ComposerEditing.wrap(in: self.string, selection: selection, open: typed, close: close))
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Bold, italic and link, as Markdown editors have them. (⌘E is Use Selection for Find; a
        // backtick typed over a selection makes it code.)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            let selection = selectedRange()
            switch key {
            case "b": apply(ComposerEditing.wrap(in: string, selection: selection, open: "**", close: "**")); return true
            case "i": apply(ComposerEditing.wrap(in: string, selection: selection, open: "*", close: "*")); return true
            case "k": apply(ComposerEditing.link(in: string, selection: selection)); return true
            default: break
            }
        }
        // ⌘Return isn't a text command; it's Send when Settings says so.
        // Return, or Enter on the keypad.
        if window?.firstResponder === self, event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           coordinator?.parent.onKey(.submit(EventModifiers(event.modifierFlags))) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        // Files are attachments, and an image with no text; anything else goes in as plain text.
        let board = NSPasteboard.general
        if board.availableType(from: [.fileURL]) != nil
            || board.availableType(from: [.string]) == nil && board.availableType(from: [.png, .tiff]) != nil {
            coordinator?.parent.onPasteOther(board)
        } else if selectedRange().length > 0, let url = board.string(forType: .string), ComposerEditing.isURL(url) {
            // A link pasted over words links them.
            apply(ComposerEditing.link(in: string, selection: selectedRange(), url: url.trimmingCharacters(in: .whitespacesAndNewlines)))
        } else {
            pasteAsPlainText(sender)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }
}

extension EventModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: EventModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }
}
