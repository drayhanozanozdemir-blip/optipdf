import XCTest
import PDFKit
import PencilKit
@testable import OptiPDF

/// Carries results out of background and completion closures.
private final class Outcome: @unchecked Sendable {
    var error: Error?
    var success = false
}

@MainActor
final class DocumentSavingTests: XCTestCase {
    private func blankDocument() throws -> PDFDocument {
        let size = CGSize(width: 595, height: 842)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        return document
    }

    private func note(_ text: String) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 220, height: 40), forType: .freeText, withProperties: nil)
        annotation.contents = text
        return annotation
    }

    private func notes(in url: URL) -> [String] {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return [] }
        return page.annotations.compactMap(\.contents)
    }

    private func temporaryPDF() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    }

    func testWrapperEncodesWhenWrittenSoLaterEditsAreIncluded() throws {
        let document = try blankDocument()
        let wrapper = PDFFileWrapper(document: document)
        document.page(at: 0)?.addAnnotation(note("after the snapshot"))
        let url = temporaryPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        PDFFileWrapper.lastEncodeOnMainThread = nil
        let outcome = Outcome()
        let written = expectation(description: "written on a background queue")
        DispatchQueue.global(qos: .userInitiated).async {
            do { try wrapper.write(to: url, options: [], originalContentsURL: nil) } catch { outcome.error = error }
            written.fulfill()
        }
        wait(for: [written], timeout: 60)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(PDFFileWrapper.lastEncodeOnMainThread, false)
        XCTAssertTrue(notes(in: url).contains("after the snapshot"))
        XCTAssertEqual(wrapper.regularFileContents, try Data(contentsOf: url))
    }

    /// SwiftUI saves documents through a UIDocument that returns our file wrapper from contents(forType:) on the
    /// main thread. The encoding has to happen later, on UIDocument's file-access queue.
    func testUIDocumentSaveEncodesOffTheMainThread() throws {
        final class SavingDocument: UIDocument {
            var pdf = PDFDocument()
            override func contents(forType typeName: String) throws -> Any { PDFFileWrapper(document: pdf) }
            override func load(fromContents contents: Any, ofType typeName: String?) throws {}
        }
        let url = temporaryPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = SavingDocument(fileURL: url)
        document.pdf = try blankDocument()
        document.pdf.page(at: 0)?.addAnnotation(note("saved by UIDocument"))
        PDFFileWrapper.lastEncodeOnMainThread = nil
        let outcome = Outcome()
        let saved = expectation(description: "saved")
        document.save(to: url, for: .forCreating) { success in
            outcome.success = success
            saved.fulfill()
        }
        wait(for: [saved], timeout: 60)
        XCTAssertTrue(outcome.success)
        XCTAssertEqual(PDFFileWrapper.lastEncodeOnMainThread, false, "UIDocument must encode the PDF off the main thread")
        XCTAssertTrue(notes(in: url).contains("saved by UIDocument"))
    }

    func testOnlyPencilStrokesCountAsDrawingEdits() throws {
        let document = try blankDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let overlays = DrawingOverlays()
        var edits = 0
        overlays.onChange = { _, _, _ in edits += 1 }
        let canvas = try XCTUnwrap(overlays.pdfView(PDFView(), overlayViewFor: page) as? PageCanvasView)
        canvas.frame = CGRect(x: 0, y: 0, width: 595, height: 842)
        func point(_ x: CGFloat, _ y: CGFloat, _ time: TimeInterval) -> PKStrokePoint {
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: time, size: CGSize(width: 4, height: 4),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                              path: PKStrokePath(controlPoints: [point(10, 10, 0), point(200, 220, 0.1)], creationDate: Date()))

        canvas.drawing = PKDrawing(strokes: [stroke])
        overlays.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(edits, 0, "a drawing set by code (page reuse, resize sync, undo) is not an edit")

        // PencilKit may report the change itself as well, and transformed drawings do not encode byte-identically,
        // so a stroke yields at least one recorded edit.
        overlays.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = PKDrawing(strokes: [stroke, stroke])
        overlays.canvasViewDrawingDidChange(canvas)
        overlays.canvasViewDidEndUsingTool(canvas)
        XCTAssertGreaterThanOrEqual(edits, 1)

        // Outside a tool session (as in «Düzelt»), one flagged change is recorded and the flag clears right away.
        canvas.userEditing = true
        canvas.drawing = PKDrawing(strokes: [stroke])
        overlays.canvasViewDrawingDidChange(canvas)
        let afterEdit = edits
        XCTAssertFalse(canvas.userEditing)
        canvas.drawing = PKDrawing(strokes: [stroke, stroke, stroke])
        overlays.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(edits, afterEdit, "after the recorded change, drawings set by code are not edits again")
        withExtendedLifetime(document) {}
    }
}
