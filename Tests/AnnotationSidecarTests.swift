import XCTest
import PDFKit
import PencilKit
@testable import OptiPDF

@MainActor
final class AnnotationSidecarTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func document(pages: Int) throws -> PDFDocument {
        let size = CGSize(width: 595, height: 842)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let document = PDFDocument()
        for index in 0..<pages { document.insert(try XCTUnwrap(PDFPage(image: image)), at: index) }
        return document
    }

    private func stroke() -> PKStroke {
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 180, y: 240)].enumerated().map { offset, location in
            PKStrokePoint(location: location, timeOffset: TimeInterval(offset) * 0.1, size: CGSize(width: 4, height: 4),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    func testNotesAndDrawingsComeBackWithoutTheBookBeingRewritten() throws {
        let book = try document(pages: 3)
        let highlight = PDFAnnotation(bounds: CGRect(x: 50, y: 700, width: 200, height: 14), forType: .highlight, withProperties: nil)
        highlight.userName = AnnotationSidecar.marker
        highlight.contents = "Merke"
        try XCTUnwrap(book.page(at: 1)).addAnnotation(highlight)
        let foreign = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 40, height: 20), forType: .square, withProperties: nil)
        try XCTUnwrap(book.page(at: 0)).addAnnotation(foreign)
        DrawingStorage.save(PKDrawing(strokes: [stroke()]), on: try XCTUnwrap(book.page(at: 2)))

        let store = AnnotationSidecar(key: "book", directory: directory)
        store.pagesChanged([0, 1, 2])
        let snapshot = store.collect(from: book)
        XCTAssertEqual(snapshot.pages.map(\.index), [1, 2], "only OptiPDF's own annotations are stored")
        store.write(pageCount: snapshot.pageCount, pages: snapshot.pages)

        let reopened = try document(pages: 3)
        let stale = PDFAnnotation(bounds: CGRect(x: 1, y: 1, width: 5, height: 5), forType: .highlight, withProperties: nil)
        stale.userName = AnnotationSidecar.marker
        try XCTUnwrap(reopened.page(at: 1)).addAnnotation(stale)
        let later = AnnotationSidecar(key: "book", directory: directory)
        XCTAssertTrue(later.apply(to: reopened))

        let notes = try XCTUnwrap(reopened.page(at: 1)).annotations.filter(AnnotationSidecar.isOurs)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.contents, "Merke")
        XCTAssertEqual(notes.first?.bounds.minX ?? 0, 50, accuracy: 0.5)
        XCTAssertEqual(DrawingStorage.load(from: try XCTUnwrap(reopened.page(at: 2)))?.strokes.count, 1)
        XCTAssertTrue(try XCTUnwrap(reopened.page(at: 0)).annotations.isEmpty)
        XCTAssertEqual(later.markedPageIndices, [1, 2])
    }

    func testTakenOverAnnotationReplacesTheOriginalInsteadOfDuplicating() throws {
        let book = try document(pages: 2)
        let original = PDFAnnotation(bounds: CGRect(x: 30, y: 30, width: 120, height: 16), forType: .underline, withProperties: nil)
        try XCTUnwrap(book.page(at: 0)).addAnnotation(original)
        original.contents = "eigene Notiz"
        original.userName = AnnotationSidecar.marker
        let store = AnnotationSidecar(key: "taken", directory: directory)
        store.pagesChanged([0])
        let snapshot = store.collect(from: book)
        store.write(pageCount: snapshot.pageCount, pages: snapshot.pages)

        let reopened = try document(pages: 2)
        try XCTUnwrap(reopened.page(at: 0)).addAnnotation(
            PDFAnnotation(bounds: CGRect(x: 30, y: 30, width: 120, height: 16), forType: .underline, withProperties: nil))
        XCTAssertTrue(AnnotationSidecar(key: "taken", directory: directory).apply(to: reopened))
        let annotations = try XCTUnwrap(reopened.page(at: 0)).annotations
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations.first?.contents, "eigene Notiz")
    }

    func testSideFileOfAnotherLayoutIsIgnoredAndEmptyNotesRemoveIt() throws {
        let book = try document(pages: 2)
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .highlight, withProperties: nil)
        note.userName = AnnotationSidecar.marker
        try XCTUnwrap(book.page(at: 1)).addAnnotation(note)
        let store = AnnotationSidecar(key: "layout", directory: directory)
        store.pagesChanged([1])
        var snapshot = store.collect(from: book)
        store.write(pageCount: snapshot.pageCount, pages: snapshot.pages)
        XCTAssertFalse(AnnotationSidecar(key: "layout", directory: directory).apply(to: try document(pages: 3)))

        try XCTUnwrap(book.page(at: 1)).removeAnnotation(note)
        snapshot = store.collect(from: book)
        store.write(pageCount: snapshot.pageCount, pages: snapshot.pages)
        XCTAssertFalse(AnnotationSidecar(key: "layout", directory: directory).apply(to: book))
    }

    func testKeyFollowsFileContent() {
        let first = AnnotationSidecar.key(for: Data("Bolognia".utf8))
        XCTAssertEqual(first, AnnotationSidecar.key(for: Data("Bolognia".utf8)))
        XCTAssertNotEqual(first, AnnotationSidecar.key(for: Data("Fitzpatrick".utf8)))
    }
}
