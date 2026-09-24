import Foundation

/// Where OptiPDF keeps what does not live in the PDF itself: the notes and drawings of large documents, the
/// reading position and bookmarks. The app's iCloud container when the entitlement and iCloud are available
/// (then the files follow the user to every device and survive a reinstall), otherwise Application Support.
final class DocumentLibrary {
    static let shared = DocumentLibrary()
    private let queue = DispatchQueue(label: "ch.ozan.optipdf.library")
    private let local: URL
    private var cloud: URL?

    init(local: URL? = nil) {
        let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        self.local = local ?? support?.appendingPathComponent("Annotations", isDirectory: true) ?? FileManager.default.temporaryDirectory
    }

    var directory: URL { queue.sync { cloud ?? local } }
    var usesCloud: Bool { queue.sync { cloud != nil } }

    /// Looks for the iCloud container once, off the main thread (the lookup can block), and moves files that were
    /// stored locally before iCloud became available.
    func prepare() {
        queue.async {
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return }
            let directory = container.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Notlar", isDirectory: true)
            let manager = FileManager.default
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in (try? manager.contentsOfDirectory(at: self.local, includingPropertiesForKeys: nil)) ?? [] {
                let target = directory.appendingPathComponent(file.lastPathComponent)
                guard !manager.fileExists(atPath: target.path) else { continue }
                if (try? manager.setUbiquitous(true, itemAt: file, destinationURL: target)) == nil {
                    try? manager.copyItem(at: file, to: target)
                }
            }
            self.cloud = directory
        }
    }
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id: Int { page }
    let page: Int
    let title: String
    let added: Date
}

/// Last page, bookmarks and recent places of one document, saved as JSON next to its notes.
final class ReadingState {
    private struct Stored: Codable {
        var lastPage: Int
        var bookmarks: [Bookmark]
        /// Places left by jumps ("Son konumlar"); missing in files written before it existed.
        var recent: [ReaderPosition]?
    }

    private(set) var lastPage: Int
    private(set) var bookmarks: [Bookmark]
    private(set) var recentPositions: [ReaderPosition]
    private let fileURL: URL
    private let queue = DispatchQueue(label: "ch.ozan.optipdf.reading", qos: .utility)
    private var pending: DispatchWorkItem?

    init(key: String, directory: URL) {
        fileURL = directory.appendingPathComponent(key + ".reading.json")
        let stored = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        lastPage = stored?.lastPage ?? 0
        bookmarks = stored?.bookmarks ?? []
        recentPositions = stored?.recent ?? []
    }

    func setLastPage(_ page: Int) {
        guard page != lastPage else { return }
        lastPage = page
        scheduleSave()
    }

    func isBookmarked(_ page: Int) -> Bool { bookmarks.contains { $0.page == page } }

    /// Adds a bookmark for the page or removes the existing one; returns whether the page is bookmarked now.
    @discardableResult
    func toggleBookmark(page: Int, title: String) -> Bool {
        if let index = bookmarks.firstIndex(where: { $0.page == page }) {
            bookmarks.remove(at: index)
            scheduleSave()
            return false
        }
        bookmarks.append(Bookmark(page: page, title: title, added: Date()))
        bookmarks.sort { $0.page < $1.page }
        scheduleSave()
        return true
    }

    func removeBookmark(page: Int) {
        bookmarks.removeAll { $0.page == page }
        scheduleSave()
    }

    func setRecentPositions(_ positions: [ReaderPosition]) {
        guard positions != recentPositions else { return }
        recentPositions = positions
        scheduleSave()
    }

    /// Writes one second after the last change.
    private func scheduleSave() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow() {
        pending?.cancel()
        pending = nil
        let stored = Stored(lastPage: lastPage, bookmarks: bookmarks, recent: recentPositions)
        let url = fileURL
        queue.async {
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Blocks until queued writes are on disk (tests).
    func waitForWrites() { queue.sync {} }
}
