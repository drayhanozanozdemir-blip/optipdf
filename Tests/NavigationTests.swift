import XCTest
import PDFKit
@testable import OptiPDF

@MainActor
final class NavigationTests: XCTestCase {
    private func makeDocument(pages: Int) throws -> PDFDocument {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for number in 1...pages {
                context.beginPage()
                ("Seite \(number)" as NSString).draw(in: bounds.insetBy(dx: 48, dy: 60),
                                                     withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func heading(_ title: String, page: Int?, in document: PDFDocument, _ children: [PDFOutline] = []) -> PDFOutline {
        let item = PDFOutline()
        item.label = title
        if let page, let target = document.page(at: page) {
            item.destination = PDFDestination(page: target, at: CGPoint(x: 0, y: 842))
        }
        for (index, child) in children.enumerated() { item.insertChild(child, at: index) }
        return item
    }

    // MARK: Page → chapter

    func testChapterLookupFollowsNestedOutline() throws {
        let document = try makeDocument(pages: 60)
        let book = heading("Dermatologie", page: 0, in: document, [
            heading("1 Grundlagen", page: 2, in: document, [
                heading("1.1 Aufbau der Haut", page: 3, in: document),
                heading("1.2 Funktion", page: 8, in: document)
            ]),
            heading("2 Bullöse Dermatosen", page: 20, in: document, [
                heading("2.1 Pemphigus", page: 20, in: document, [
                    heading("2.1.1 Pemphigus vulgaris", page: 22, in: document)
                ]),
                heading("2.2 Pemphigoid", page: 30, in: document)
            ]),
            heading("Anhang", page: nil, in: document, [
                heading("Register", page: 50, in: document)
            ])
        ])
        let root = PDFOutline()
        root.insertChild(book, at: 0)
        document.outlineRoot = root

        let index = ChapterIndex(document: document)
        typealias Location = ChapterIndex.Location
        XCTAssertNil(index.location(for: 0), "the book's title is a wrapper, not a chapter")
        XCTAssertNil(index.location(for: 1))
        XCTAssertEqual(index.location(for: 2), Location(chapter: "1 Grundlagen", section: nil))
        XCTAssertEqual(index.location(for: 5), Location(chapter: "1 Grundlagen", section: "1.1 Aufbau der Haut"))
        XCTAssertEqual(index.location(for: 19), Location(chapter: "1 Grundlagen", section: "1.2 Funktion"))
        XCTAssertEqual(index.location(for: 20), Location(chapter: "2 Bullöse Dermatosen", section: "2.1 Pemphigus"))
        XCTAssertEqual(index.location(for: 25), Location(chapter: "2 Bullöse Dermatosen", section: "2.1.1 Pemphigus vulgaris"))
        XCTAssertEqual(index.location(for: 30), Location(chapter: "2 Bullöse Dermatosen", section: "2.2 Pemphigoid"))
        XCTAssertEqual(index.location(for: 59), Location(chapter: "Anhang", section: "Register"),
                       "a heading without its own link starts at its first sub-heading")
        XCTAssertNil(index.labels, "page labels equal to the page numbers are not kept")
    }

    func testChapterLookupHandlesActionsDisorderAndEmptyHeadings() throws {
        let document = try makeDocument(pages: 40)
        let root = PDFOutline()
        let viaAction = PDFOutline()
        viaAction.label = "C  Über\nAktion"
        viaAction.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(document.page(at: 35)), at: .zero))
        let children = [heading("B Später", page: 30, in: document), heading("A Früher", page: 10, in: document),
                        viaAction, heading("Ohne Ziel", page: nil, in: document)]
        for (position, child) in children.enumerated() { root.insertChild(child, at: position) }
        document.outlineRoot = root

        let index = ChapterIndex(document: document)
        XCTAssertNil(index.location(for: 5))
        XCTAssertEqual(index.location(for: 12)?.chapter, "A Früher")
        XCTAssertEqual(index.location(for: 31)?.chapter, "B Später")
        XCTAssertEqual(index.location(for: 39)?.chapter, "C Über Aktion")
        XCTAssertTrue(ChapterIndex(document: try makeDocument(pages: 3)).isEmpty, "no outline, no chapters")
    }

    func testSectionsStayInTheirChapterAndLabelsResolve() {
        let index = ChapterIndex(outline: [
            .init(page: 10, title: "Kapitel 1", depth: 0),
            .init(page: 40, title: "1.1 Falsch einsortiert", depth: 1),
            .init(page: 30, title: "Kapitel 2", depth: 0),
            .init(page: 32, title: "2.1 Richtig", depth: 1)
        ], labels: ["i", "ii", "1", "2", "3"])
        XCTAssertEqual(index.location(for: 35), ChapterIndex.Location(chapter: "Kapitel 2", section: "2.1 Richtig"))
        XCTAssertEqual(index.location(for: 45), ChapterIndex.Location(chapter: "Kapitel 2", section: "2.1 Richtig"))
        XCTAssertEqual(index.location(for: 12), ChapterIndex.Location(chapter: "Kapitel 1", section: nil))
        XCTAssertEqual(index.pageIndex(forLabel: " II "), 1)
        XCTAssertEqual(index.pageIndex(forLabel: "3"), 4)
        XCTAssertNil(index.pageIndex(forLabel: "x"))
    }

    // MARK: Jump history

    func testHistoryGoesBackAndForwardToExactPlaces() {
        var history = JumpHistory()
        let reading = ReaderPosition(page: 244, offset: CGPoint(x: 0, y: 312_345.5), contentSize: CGSize(width: 820, height: 1_900_000),
                                     scale: 1.25, mode: "continuous")
        XCTAssertTrue(history.record(from: reading, to: 899))
        XCTAssertEqual(history.back, [reading])
        let far = ReaderPosition(page: 899, offset: CGPoint(x: 0, y: 1_000_000))
        XCTAssertEqual(history.goBack(from: far), reading)
        XCTAssertFalse(history.canGoBack)
        XCTAssertEqual(history.forward, [far])
        XCTAssertEqual(history.goForward(from: reading), far)
        XCTAssertEqual(history.back, [reading])
        XCTAssertNil(history.goForward(from: far))
        XCTAssertEqual(history.goBack(from: far), reading)
        XCTAssertNil(history.goBack(from: reading))
    }

    func testNewJumpClearsForwardAndSamePageIsNoJump() {
        var history = JumpHistory()
        XCTAssertFalse(history.record(from: ReaderPosition(page: 5), to: 5))
        XCTAssertFalse(history.canGoBack)
        history.record(from: ReaderPosition(page: 1), to: 10)
        history.record(from: ReaderPosition(page: 10), to: 20)
        _ = history.goBack(from: ReaderPosition(page: 20))
        XCTAssertTrue(history.canGoForward)
        history.record(from: ReaderPosition(page: 10), to: 30)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.back.map(\.page), [1, 10])
    }

    func testSearchResultsAndScrubbingKeepTheFirstPlace() {
        var history = JumpHistory()
        let start = Date()
        history.record(from: ReaderPosition(page: 244), to: 600, kind: .search, at: start)
        history.record(from: ReaderPosition(page: 600), to: 612, kind: .search, at: start + 5)
        history.record(from: ReaderPosition(page: 612), to: 700, kind: .search, at: start + 10)
        XCTAssertEqual(history.back.map(\.page), [244])
        // Reading a result for longer, or another kind of jump, leaves a new place.
        history.record(from: ReaderPosition(page: 700), to: 800, kind: .search, at: start + 200)
        history.record(from: ReaderPosition(page: 800), to: 900, kind: .other, at: start + 201)
        history.record(from: ReaderPosition(page: 900), to: 950, kind: .other, at: start + 202)
        XCTAssertEqual(history.back.map(\.page), [244, 700, 800, 900])
        history.record(from: ReaderPosition(page: 950), to: 100, kind: .scrub, at: start + 203)
        history.record(from: ReaderPosition(page: 100), to: 120, kind: .scrub, at: start + 205)
        XCTAssertEqual(history.back.map(\.page), [244, 700, 800, 900, 950])
        // Scrubbing away from somewhere else is a new place again.
        history.record(from: ReaderPosition(page: 130), to: 10, kind: .scrub, at: start + 206)
        XCTAssertEqual(history.back.last?.page, 130)
    }

    func testHistoryLimitAndRecentPlaces() {
        var history = JumpHistory(limit: 3, recentLimit: 4)
        for step in 0..<6 { history.record(from: ReaderPosition(page: step * 10), to: step * 10 + 5) }
        XCTAssertEqual(history.back.map(\.page), [30, 40, 50])
        XCTAssertEqual(history.recent.map(\.page), [50, 40, 30, 20])
        history.record(from: ReaderPosition(page: 30), to: 90)
        XCTAssertEqual(history.recent.map(\.page), [30, 50, 40, 20], "a place visited again moves to the front")
        XCTAssertEqual(history.recentPositions(excluding: 50, limit: 2).map(\.page), [30, 40])
        let reopened = JumpHistory(recent: history.recent, recentLimit: 2)
        XCTAssertEqual(reopened.recent.map(\.page), [30, 50])
        XCTAssertFalse(reopened.canGoBack)
        history.reset()
        XCTAssertTrue(history.recent.isEmpty && !history.canGoBack && !history.canGoForward)
    }

    // MARK: Go to page

    func testGoToPageParsingAndClamping() {
        func page(_ text: String, _ count: Int = 1514) -> Int? { PageNumberInput.pageIndex(from: text, pageCount: count) }
        XCTAssertEqual(page("245"), 244)
        XCTAssertEqual(page(" 245 "), 244)
        XCTAssertEqual(page("S. 245"), 244)
        XCTAssertEqual(page("245."), 244)
        XCTAssertEqual(page("1.514"), 1513)
        XCTAssertEqual(page("1 514"), 1513)
        XCTAssertEqual(page("245-250"), 244)
        XCTAssertEqual(page("0"), 0)
        XCTAssertEqual(page("1"), 0)
        XCTAssertEqual(page("2000"), 1513)
        XCTAssertEqual(page("99999999999999999999"), 1513)
        XCTAssertNil(page(""))
        XCTAssertNil(page("abc"))
        XCTAssertNil(page("12", 0))
    }

    func testTurkishDativeFollowsTheSpokenNumber() {
        XCTAssertEqual(TurkishText.dative(123), "123'e")
        XCTAssertEqual(TurkishText.dative(6), "6'ya")
        XCTAssertEqual(TurkishText.dative(9), "9'a")
        XCTAssertEqual(TurkishText.dative(2), "2'ye")
        XCTAssertEqual(TurkishText.dative(40), "40'a")
        XCTAssertEqual(TurkishText.dative(50), "50'ye")
        XCTAssertEqual(TurkishText.dative(100), "100'e")
        XCTAssertEqual(TurkishText.dative(1000), "1000'e")
        XCTAssertEqual(TurkishText.dative(1500), "1500'e")
        XCTAssertEqual(TurkishText.dative(1514), "1514'e")
    }

    // MARK: Persistence and thumbnails

    func testReadingStateKeepsRecentPlacesAndReadsOlderFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let place = ReaderPosition(page: 122, offset: CGPoint(x: 0, y: 4567.25), contentSize: CGSize(width: 820, height: 1_300_000),
                                   scale: 1.1, mode: "continuous")
        let state = ReadingState(key: "book", directory: directory)
        state.setLastPage(122)
        state.setRecentPositions([place, ReaderPosition(page: 7)])
        state.saveNow()
        state.waitForWrites()
        let reopened = ReadingState(key: "book", directory: directory)
        XCTAssertEqual(reopened.lastPage, 122)
        XCTAssertEqual(reopened.recentPositions, [place, ReaderPosition(page: 7)])

        try Data(#"{"lastPage":41,"bookmarks":[]}"#.utf8).write(to: directory.appendingPathComponent("old.reading.json"))
        let older = ReadingState(key: "old", directory: directory)
        XCTAssertEqual(older.lastPage, 41)
        XCTAssertEqual(older.recentPositions, [])
    }

    func testOrganizerThumbnailsRenderOffMainAndAreCached() async throws {
        let document = try makeDocument(pages: 3)
        let thumbnails = PageThumbnails()
        XCTAssertNil(thumbnails.cached(index: 1, revision: 0))
        let image = await thumbnails.render(page: 1, of: document, revision: 0)
        XCTAssertNotNil(image)
        XCTAssertNotNil(thumbnails.cached(index: 1, revision: 0))
        XCTAssertNil(thumbnails.cached(index: 1, revision: 1), "a page edit (new revision) renders again")
        let missing = await thumbnails.render(page: 9, of: document, revision: 0)
        XCTAssertNil(missing)
    }
}
