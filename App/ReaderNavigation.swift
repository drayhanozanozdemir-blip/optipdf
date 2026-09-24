import SwiftUI
import PDFKit
import Combine

/// Moving around large PDFs: the page scrubber, the jump history (back, forward, "Son konumlar"), the chapter
/// lookup and "Sayfaya git". One per editor (EditorModel.navigation); the UIKit part (PageScrubber) lives in the
/// PDF controller's view, the SwiftUI part in ReaderNavigationViews.swift.
@MainActor
final class ReaderNavigation: ObservableObject {
    @Published private(set) var history = JumpHistory()
    @Published private(set) var chapters: ChapterIndex?
    @Published private(set) var capsuleVisible = false
    @Published var showGoTo = false
    @Published var showOrganizer = false
    /// The go-to sheet's "Sayfalar" row: the organizer opens once that sheet is gone.
    var organizerAfterGoTo = false
    let thumbnails = PageThumbnails()
    private(set) var scrubber: PageScrubber?
    private weak var model: EditorModel?
    private weak var reading: ReadingState?
    private var building = false
    private var capsuleTimer: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    init(model: EditorModel) {
        self.model = model
        // The menus and the indicator live in EditorView, which observes the model.
        objectWillChange
            .sink { [weak model] _ in model?.objectWillChange.send() }
            .store(in: &subscriptions)
        model.$pageRevision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pagesChanged() }
            .store(in: &subscriptions)
        let chrome: [AnyPublisher<Void, Never>] = [
            model.$fullscreen.map { _ in () }.eraseToAnyPublisher(),
            model.$hudVisible.map { _ in () }.eraseToAnyPublisher(),
            model.$selectionText.map { _ in () }.eraseToAnyPublisher(),
            model.$isSelecting.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(chrome)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scrubber?.chromeChanged() }
            .store(in: &subscriptions)
    }

    /// From the controller's viewDidLoad.
    func attach(to controller: PDFEditorController) {
        scrubber?.detach()
        scrubber = PageScrubber(controller: controller, navigation: self)
        reading = controller.reading
        let recent = controller.reading?.recentPositions ?? []
        if !recent.isEmpty {
            // Not while SwiftUI is still making the view.
            DispatchQueue.main.async { [weak self] in self?.history = JumpHistory(recent: recent) }
        }
    }

    // MARK: Jumps

    var backPage: Int? { history.back.last?.page }
    var forwardPage: Int? { history.forward.last?.page }
    var backTitle: String { backPage.map { "S. \(TurkishText.dative($0 + 1)) dön" } ?? "Geri dön" }
    var forwardTitle: String { forwardPage.map { "S. \(TurkishText.dative($0 + 1)) git" } ?? "İleri git" }

    /// Right before the reader jumps to `page`: remembers where they are.
    func willJump(to page: Int, kind: JumpKind = .other) {
        guard let from = model?.controller?.readerPosition() else { return }
        record(from: from, to: page, kind: kind)
    }

    func record(from: ReaderPosition, to page: Int, kind: JumpKind) {
        guard from.page != page else { return }
        history.record(from: from, to: page, kind: kind)
        reading?.setRecentPositions(history.recent)
        if history.canGoBack { showCapsule() }
        model?.controller?.restoreReaderFocusSoon()
    }

    func goBack() {
        guard let controller = model?.controller, let current = controller.readerPosition(),
              let target = history.goBack(from: current) else { return }
        controller.restore(target)
        movedInHistory()
    }

    func goForward() {
        guard let controller = model?.controller, let current = controller.readerPosition(),
              let target = history.goForward(from: current) else { return }
        controller.restore(target)
        movedInHistory()
    }

    /// A place from "Son konumlar": a jump like any other, restored exactly.
    func jump(to position: ReaderPosition) {
        guard let controller = model?.controller else { return }
        if let from = controller.readerPosition() { record(from: from, to: position.page, kind: .other) }
        controller.restore(position)
    }

    func recentPositions(excluding page: Int) -> [ReaderPosition] {
        history.recentPositions(excluding: page, limit: 5)
    }

    private func movedInHistory() {
        reading?.setRecentPositions(history.recent)
        showCapsule()
        model?.controller?.restoreReaderFocusSoon()
    }

    /// "‹ S. 123'e dön" for 8 seconds after a jump.
    private func showCapsule() {
        capsuleVisible = true
        capsuleTimer?.cancel()
        capsuleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.capsuleVisible = false
        }
    }

    // MARK: Chapters

    func chapterTitle(for page: Int) -> String? {
        guard let title = chapters?.location(for: page)?.chapter, !title.isEmpty else { return nil }
        return title
    }

    /// Builds the page → chapter lookup once, off the main thread (large outlines take a while to read).
    func prepareChapters() {
        guard chapters == nil, !building, let document = model?.controller?.document else { return }
        building = true
        let revision = model?.pageRevision ?? 0
        let source = OutlineSource(document: document)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let index = ChapterIndex(document: source.document)
            DispatchQueue.main.async {
                guard let self else { return }
                self.building = false
                guard self.model?.pageRevision == revision else { return self.prepareChapters() }
                self.chapters = index
            }
        }
    }

    /// Pages were moved, inserted or deleted: page numbers in the history and the lookup are stale.
    private func pagesChanged() {
        history.reset()
        reading?.setRecentPositions([])
        capsuleVisible = false
        chapters = nil
        thumbnails.removeAll()
        scrubber?.pagesChanged()
    }
}

// MARK: - Reader hooks

extension PDFEditorController {
    /// Hook from viewDidLoad: page scrubber, jump history, link jumps.
    func installNavigation() {
        model?.navigation.attach(to: self)
    }

    /// Hook before every jump (outline, search result, bookmark, note, go to page): remembers where the reader was.
    func noteJump(to page: PDFPage?, kind: JumpKind = .other) {
        guard let page, let navigation = model?.navigation else { return }
        let index = document.index(for: page)
        guard index != NSNotFound, index >= 0 else { return }
        navigation.willJump(to: index, kind: kind)
    }

    /// Where the reader is, precise enough to come back to exactly.
    func readerPosition() -> ReaderPosition? {
        guard let page = pdfView.currentPage else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound, index >= 0 else { return nil }
        var position = ReaderPosition(page: index)
        let mode = model?.displayMode ?? "continuous"
        if mode != "page", let scroll = scrollView {
            position.offset = scroll.contentOffset
            position.contentSize = scroll.contentSize
            position.scale = pdfView.scaleFactor
            position.mode = mode
            let rect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            if rect.height > 1 { position.within = min(max(-rect.minY / rect.height, 0), 1) }
        }
        return position
    }

    /// Back to a remembered place: the exact offset while zoom, layout and window size are unchanged, else the page.
    func restore(_ position: ReaderPosition) {
        guard document.pageCount > 0 else { return }
        let mode = model?.displayMode ?? "continuous"
        if mode != "page", position.mode == mode, let offset = position.offset, let size = position.contentSize,
           let scale = position.scale, let scroll = scrollView,
           abs(scroll.contentSize.width - size.width) < 1, abs(scroll.contentSize.height - size.height) < 1,
           abs(pdfView.scaleFactor - scale) < 0.0005 {
            let inset = scroll.adjustedContentInset
            let maximum = CGPoint(x: max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right),
                                  y: max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom))
            let target = CGPoint(x: min(maximum.x, max(-inset.left, offset.x)), y: min(maximum.y, max(-inset.top, offset.y)))
            scroll.setContentOffset(target, animated: false)
            return
        }
        guard let page = document.page(at: min(max(position.page, 0), document.pageCount - 1)) else { return }
        pdfView.go(to: page)
        // Zoom, layout or window size changed: the same spot on the page.
        guard mode != "page", let within = position.within, within > 0, let scroll = scrollView else { return }
        let rect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
        guard rect.height > 1 else { return }
        let inset = scroll.adjustedContentInset
        let maximumY = max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
        let y = min(maximumY, max(-inset.top, scroll.contentOffset.y + rect.minY + within * rect.height))
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
    }

    /// ⌘[ back, ⌘] forward, ⌘L "Sayfaya git"; offered only when keyboardNavigationAvailable (README focus rules).
    var navigationKeyCommands: [UIKeyCommand] {
        let commands: [(String, String, Selector)] = [
            ("[", "Geri dön", #selector(jumpBackFromKeyboard)),
            ("]", "İleri git", #selector(jumpForwardFromKeyboard)),
            ("l", "Sayfaya git…", #selector(goToPageFromKeyboard))
        ]
        return commands.map { input, title, action in
            let command = UIKeyCommand(input: input, modifierFlags: .command, action: action)
            command.discoverabilityTitle = title
            return command
        }
    }

    @objc func jumpBackFromKeyboard() {
        guard keyboardNavigationAvailable else { return }
        model?.navigation.goBack()
    }

    @objc func jumpForwardFromKeyboard() {
        guard keyboardNavigationAvailable else { return }
        model?.navigation.goForward()
    }

    @objc func goToPageFromKeyboard() {
        guard keyboardNavigationAvailable else { return }
        model?.navigation.showGoTo = true
    }

    /// Arrow keys and the tool picker need the reader as first responder again after a sheet or a jump; never while
    /// text is being entered, a sheet is up or the notes panel is open.
    func restoreReaderFocus() {
        guard keyboardNavigationAvailable, !isFirstResponder else { return }
        becomeFirstResponder()
    }

    func restoreReaderFocusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.restoreReaderFocus() }
    }
}

// MARK: - Organizer thumbnails

/// Thumbnails for the page organizer: rendered off the main thread two at a time and kept in an NSCache. A row that
/// scrolls away before its turn is skipped, so flicking through 1500 pages does not queue 1500 renders.
@MainActor
final class PageThumbnails {
    private let cache = NSCache<NSString, UIImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ch.ozan.optipdf.thumbnails"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init() {
        cache.countLimit = 600
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cached(index: Int, revision: Int) -> UIImage? {
        cache.object(forKey: Self.key(index, revision))
    }

    func render(page index: Int, of document: PDFDocument, revision: Int) async -> UIImage? {
        let key = Self.key(index, revision)
        if let image = cache.object(forKey: key) { return image }
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { return nil }
        let ticket = RenderTicket()
        let job = ThumbnailJob(page: page, cache: cache, key: key, ticket: ticket)
        let queue = self.queue
        let rendered: RenderedThumbnail = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.addOperation { continuation.resume(returning: job.run()) }
            }
        } onCancel: {
            ticket.cancel()
        }
        return rendered.image
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private static func key(_ index: Int, _ revision: Int) -> NSString {
        "\(revision)-\(index)" as NSString
    }
}

/// PDFKit reads the outline and page labels off the main thread; nothing mutates the document meanwhile except page
/// edits, which rebuild the lookup (pageRevision).
private struct OutlineSource: @unchecked Sendable {
    let document: PDFDocument
}

private final class RenderTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private struct RenderedThumbnail: @unchecked Sendable {
    let image: UIImage?
}

private struct ThumbnailJob: @unchecked Sendable {
    static let size = CGSize(width: 128, height: 172)
    let page: PDFPage
    let cache: NSCache<NSString, UIImage>
    let key: NSString
    let ticket: RenderTicket

    func run() -> RenderedThumbnail {
        guard !ticket.isCancelled else { return RenderedThumbnail(image: nil) }
        let image = page.thumbnail(of: Self.size, for: .cropBox)
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return RenderedThumbnail(image: image)
    }
}
