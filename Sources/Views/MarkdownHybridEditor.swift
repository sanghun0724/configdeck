import SwiftUI
import AppKit

/// Obsidian-style hybrid live-preview editor.
///
/// The paragraph holding the cursor stays raw (markup visible) so editing is
/// predictable; every other line is styled and its markup markers are hidden.
/// Plain text is the source of truth — only display attributes change, the
/// underlying string is never rewritten, so WriteGuard saves the exact bytes.
struct MarkdownHybridEditor: NSViewRepresentable {
    @Binding var text: String
    /// Bumped by the host view to request the native find bar (⌘F); any change
    /// in value triggers a single show.
    var findTrigger: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.delegate = context.coordinator
        textView.isRichText = false           // we own attributes; paste stays plain
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.font = MarkdownStyler.baseFont
        textView.textContainerInset = NSSize(width: MarkdownTheme.editorInset, height: 16)
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.fullRestyle(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // External change (discard/restore/load) — replace and restyle.
        if textView.string != text {
            let sel = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            context.coordinator.fullRestyle(textView)
        }
        if context.coordinator.lastFindTrigger != findTrigger {
            context.coordinator.lastFindTrigger = findTrigger
            context.coordinator.showFindBar(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: MarkdownHybridEditor
        weak var textView: NSTextView?
        private var lastActiveParagraph: NSRange?
        var lastFindTrigger = 0

        init(_ parent: MarkdownHybridEditor) { self.parent = parent }

        func showFindBar(_ tv: NSTextView) {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            tv.performTextFinderAction(item)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            fullRestyle(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, let storage = tv.textStorage else { return }
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let active = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
            let previous = lastActiveParagraph
            // Cursor moved within the already-active paragraph — nothing changed.
            guard active != previous else { return }
            lastActiveParagraph = active
            // Only touch the paragraph losing raw state and the one gaining it —
            // every other line's attributes (and layout) stay untouched, so there's
            // no reflow elsewhere in the document to drag the scroll position.
            if let previous, NSMaxRange(previous) <= ns.length {
                MarkdownStyler.restyleLines(storage, in: previous, selected: sel)
            }
            MarkdownStyler.restyleLines(storage, in: active, selected: sel)
        }

        /// Restyles the whole document — only for actual content changes (typing,
        /// load, discard, restore), never for a plain cursor move.
        func fullRestyle(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let sel = tv.selectedRange()
            MarkdownStyler.apply(to: storage, selected: sel)
            let ns = tv.string as NSString
            lastActiveParagraph = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        }
    }
}
