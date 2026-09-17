import XCTest
import PDFKit
import PencilKit
@testable import OptiPDF

@MainActor
final class ReaderFeaturesTests: XCTestCase {
    private func textDocument(pages: Int) throws -> PDFDocument {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for number in 1...pages {
                context.beginPage()
                let text = "Seite \(number). Psoriasis vulgaris zeigt silbrige Schuppung."
                (text as NSString).draw(in: bounds.insetBy(dx: 48, dy: 60),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
            }
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }

    func testReadingStateRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = ReadingState(key: "book", directory: directory)
        state.setLastPage(41)
        XCTAssertTrue(state.toggleBookmark(page: 41, title: "Psoriasis"))
        XCTAssertTrue(state.toggleBookmark(page: 3, title: "Einleitung"))
        XCTAssertFalse(state.toggleBookmark(page: 41, title: "Psoriasis"))
        state.saveNow()
        state.waitForWrites()
        let reopened = ReadingState(key: "book", directory: directory)
        XCTAssertEqual(reopened.lastPage, 41)
        XCTAssertEqual(reopened.bookmarks.map(\.page), [3])
        XCTAssertEqual(reopened.bookmarks.first?.title, "Einleitung")
        XCTAssertTrue(reopened.isBookmarked(3))
    }

    func testInkAnnotationsFollowPageRotation() throws {
        let page = try XCTUnwrap(try textDocument(pages: 1).page(at: 0))
        func point(_ x: CGFloat, _ y: CGFloat) -> PKStrokePoint {
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: 0, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .red),
                              path: PKStrokePath(controlPoints: [point(10, 20), point(110, 20)], creationDate: Date()))
        let drawing = PKDrawing(strokes: [stroke])

        let upright = PDFEditorController.inkAnnotations(for: drawing, on: page)
        let path = try XCTUnwrap(upright.first?.paths?.first)
        XCTAssertEqual(path.bounds.minX, 10, accuracy: 3)
        XCTAssertEqual(path.bounds.maxX, 110, accuracy: 3)
        XCTAssertEqual(path.bounds.midY, 822, accuracy: 3, "display y 20 from the top is 822 from the bottom")

        page.rotation = 90
        let rotated = PDFEditorController.inkAnnotations(for: drawing, on: page)
        let rotatedPath = try XCTUnwrap(rotated.first?.paths?.first)
        XCTAssertEqual(rotatedPath.bounds.midX, 20, accuracy: 3)
        XCTAssertEqual(rotatedPath.bounds.minY, 10, accuracy: 3)
        XCTAssertEqual(rotatedPath.bounds.maxY, 110, accuracy: 3)
    }

    func testOverlayPassesTouchesThroughUnlessDrawingAndTints() {
        let overlay = PageOverlayView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        overlay.canvas.isUserInteractionEnabled = false
        XCTAssertNil(overlay.hitTest(CGPoint(x: 50, y: 50), with: nil))
        overlay.canvas.isUserInteractionEnabled = true
        let hit = overlay.hitTest(CGPoint(x: 50, y: 50), with: nil)
        XCTAssertNotNil(hit)
        XCTAssertFalse(hit === overlay)

        overlay.apply(.sepia)
        XCTAssertFalse(overlay.tint.isHidden)
        XCTAssertEqual(overlay.tint.layer.compositingFilter as? String, "multiplyBlendMode")
        overlay.apply(.night)
        XCTAssertEqual(overlay.tint.layer.compositingFilter as? String, "differenceBlendMode")
        overlay.apply(.normal)
        XCTAssertTrue(overlay.tint.isHidden)
    }

    func testSearchDeliversMatchesAndFinishes() throws {
        let controller = PDFEditorController(document: try textDocument(pages: 40))
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        let finished = expectation(description: "search finished")
        var count = 0
        controller.search("Psoriasis") { matches, done in
            count = matches.count
            if done { finished.fulfill() }
        }
        wait(for: [finished], timeout: 30)
        XCTAssertEqual(count, 40)
        XCTAssertEqual(controller.pdfView.highlightedSelections?.count, 40)
    }
}
