import Foundation

/// Watches one file for external changes via DispatchSource and fires `onChange`
/// on the main queue. Atomic writes and editors replace the file node, which kills
/// the open descriptor — so the watcher re-arms itself on the *path* after every
/// event, and polls until the path exists when the file is missing (fresh installs
/// create settings.json on first save).
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    deinit { source?.cancel() }

    private func arm() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist (yet) — poll until it does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.fire() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func fire() {
        onChange()
        // Re-arm on the path: after a rename/delete (atomic replace) the old fd is dead.
        source?.cancel()
        source = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.arm() }
    }
}
