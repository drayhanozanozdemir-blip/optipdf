import XCTest
import PDFKit
@testable import OptiPDF

@MainActor
final class HighlightToolTests: XCTestCase {
    private var savedColor: String?
    private var directory: URL!

    override func setUp() {
        super.setUp()
        savedColor = UserDefaults.standard.string(forKey: HighlightColor.storageKey)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedColor, forKey: HighlightColor.storageKey)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: Helpers

    /// A generated textbook page: one long paragraph that wraps over many lines.
    private func paragraphDocument(pages: Int = 1) throws -> PDFDocument {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let paragraph = String(repeating: "Psoriasis vulgaris zeigt scharf begrenzte erythematöse Plaques mit silbriger Schuppung. ",
                               count: 10)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for _ in 0..<pages {
                context.beginPage()
                (paragraph as NSString).draw(in: bounds.insetBy(dx: 48, dy: 60),
                                             withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
            }
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }

    /// The text lines of a page, top to bottom.
    private func textLines(of page: PDFPage) throws -> [PDFSelection] {
        let lines = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox))).selectionsByLine()
        XCTAssertGreaterThanOrEqual(lines.count, 8)
        return lines
    }

    /// From the middle of the first line to the middle of the third.
    private func threeLineSelection(on page: PDFPage) throws -> PDFSelection {
        let lines = try textLines(of: page)
        let first = lines[0].bounds(for: page)
        let third = lines[2].bounds(for: page)
        return try XCTUnwrap(page.selection(from: CGPoint(x: first.midX, y: first.midY), to: CGPoint(x: third.midX, y: third.midY)))
    }

    /// A reader without a window; its undo groups only what `grouped` wraps.
    private func editor(for document: PDFDocument) -> (PDFEditorController, UndoManager) {
        let controller = PDFEditorController(document: document)
        controller.loadViewIfNeeded()
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.undo = undo
        return (controller, undo)
    }

    @discardableResult
    private func grouped<T>(_ undo: UndoManager, _ work: () throws -> T) rethrows -> T {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return try work()
    }

    private func noteItems(in document: PDFDocument) -> [NoteItem] {
        var items: [NoteItem] = []
        for index in 0..<document.pageCount { EditorModel.appendNotes(from: document, at: index, to: &items) }
        return items
    }

    private func assertColor(_ actual: UIColor?, _ expected: UIColor, file: StaticString = #filePath, line: UInt = #line) {
        guard let a = HighlightColor.components(of: actual), let e = HighlightColor.components(of: expected) else {
            return XCTFail("missing colour", file: file, line: line)
        }
        XCTAssertEqual(a.r, e.r, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(a.g, e.g, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(a.b, e.b, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(a.a, e.a, accuracy: 0.02, file: file, line: line)
    }

    /// WCAG contrast ratio of two sRGB colours.
    private func contrast(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func luminance(_ c: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
            0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
        }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    // MARK: Tests

    func testMultiLineHighlightMakesOneQuadPerLine() throws {
        let document = try paragraphDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let (controller, undo) = editor(for: document)
        let lines = try textLines(of: page)
        let selection = try threeLineSelection(on: page)
        let marks = grouped(undo) {
            controller.markSelection(.highlight, color: HighlightColor.sari.highlightColor, selection: selection)
        }
        XCTAssertEqual(marks.count, 3, "one annotation per line")
        for (_, annotation) in marks {
            let quad = try XCTUnwrap(annotation.quadrilateralPoints).map(\.cgPointValue)
            XCTAssertEqual(quad.count, 4, "one quad per line")
            let box = annotation.bounds
            let relative = CGRect(x: quad.map(\.x).min() ?? 0, y: quad.map(\.y).min() ?? 0,
                                  width: (quad.map(\.x).max() ?? 0) - (quad.map(\.x).min() ?? 0),
                                  height: (quad.map(\.y).max() ?? 0) - (quad.map(\.y).min() ?? 0))
            let covers = MarkGeometry.same(relative.offsetBy(dx: box.minX, dy: box.minY), box)
                || MarkGeometry.same(relative, box)
            XCTAssertTrue(covers, "the quad spans its line: \(quad) for \(box)")
        }
        XCTAssertEqual(Set(marks.compactMap { $0.1.modificationDate }).count, 1, "one stamp for the whole mark")

        // Drawn over the selected part of the lines only.
        let raster = try PageRaster(page)
        let middle = raster.average(in: marks[1].1.bounds.insetBy(dx: 2, dy: 1))
        XCTAssertGreaterThan(middle.r - middle.b, 0.15, "the highlight is drawn over its line: \(middle)")
        let untouched = raster.average(in: lines[5].bounds(for: page))
        XCTAssertLessThan(abs(untouched.r - untouched.b), 0.05, "other lines stay white: \(untouched)")
        let firstLine = lines[0].bounds(for: page)
        let before = CGRect(x: firstLine.minX, y: firstLine.minY + 1,
                            width: marks[0].1.bounds.minX - firstLine.minX - 6, height: firstLine.height - 2)
        if before.width > 20 {
            let start = raster.average(in: before)
            XCTAssertLessThan(abs(start.r - start.b), 0.05, "the first line is highlighted from the start point on: \(start)")
        }

        // The notes list shows one mark; saving keeps the quads and the grouping.
        XCTAssertEqual(noteItems(in: document).map(\.pairs.count), [3])
        let saved = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(document.dataRepresentation())))
        let savedMarks = try XCTUnwrap(saved.page(at: 0)).annotations.filter { $0.markType == "Highlight" }
        XCTAssertEqual(savedMarks.count, 3)
        XCTAssertTrue(savedMarks.allSatisfy { $0.quadrilateralPoints?.count == 4 })
        XCTAssertEqual(noteItems(in: saved).map(\.pairs.count), [3])
    }

    func testSeparateHighlightsStayApartAfterSaving() throws {
        let document = try paragraphDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let (controller, undo) = editor(for: document)
        let lines = try textLines(of: page)
        grouped(undo) { controller.markSelection(.highlight, selection: lines[3]) }
        grouped(undo) { controller.markSelection(.highlight, selection: lines[4]) }
        let saved = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(document.dataRepresentation())))
        XCTAssertEqual(noteItems(in: saved).count, 2, "two highlights made within one second stay two notes")
    }

    func testRecolorChangesEveryLineAndUndoes() throws {
        let document = try paragraphDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let (controller, undo) = editor(for: document)
        let selection = try threeLineSelection(on: page)
        let marks = grouped(undo) {
            controller.markSelection(.highlight, color: HighlightColor.sari.highlightColor, selection: selection)
        }
        grouped(undo) { controller.recolor(marks, to: .mavi) }
        for (_, annotation) in marks { assertColor(annotation.color, HighlightColor.mavi.highlightColor) }
        undo.undo()
        for (_, annotation) in marks { assertColor(annotation.color, HighlightColor.sari.highlightColor) }
        undo.redo()
        XCTAssertTrue(marks.allSatisfy { HighlightColor.match($0.1.color) == .mavi })
        XCTAssertEqual(noteItems(in: document).first.flatMap { NotesExport.color(of: $0) }, .mavi)

        // Lines take the darker shade.
        let lineSix = try textLines(of: page)[6]
        let underline = grouped(undo) { controller.markSelection(.underline, selection: lineSix) }
        grouped(undo) { controller.recolor(underline, to: .pembe) }
        assertColor(underline.first?.1.color, HighlightColor.pembe.lineColor)
    }

    func testLastColourPersistsAndIsTheDefault() throws {
        HighlightColor.last = .pembe
        XCTAssertEqual(UserDefaults.standard.string(forKey: HighlightColor.storageKey), "pembe")
        XCTAssertEqual(HighlightColor.last, .pembe)
        UserDefaults.standard.set("lila", forKey: HighlightColor.storageKey)
        XCTAssertEqual(HighlightColor.last, .sari, "an unknown value falls back to yellow")

        HighlightColor.last = .turuncu
        let document = try paragraphDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let (controller, undo) = editor(for: document)
        let line = try textLines(of: page)[2]
        let marks = grouped(undo) { controller.markSelection(.highlight, selection: line) }
        assertColor(marks.first?.1.color, HighlightColor.turuncu.highlightColor)
    }

    func testNoteEditRoundTripsAndUndoes() throws {
        let document = try paragraphDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let (controller, undo) = editor(for: document)
        let selection = try threeLineSelection(on: page)
        let marks = grouped(undo) { controller.markSelection(.highlight, note: "Merke", selection: selection) }
        let item = try XCTUnwrap(noteItems(in: document).first)
        XCTAssertEqual(item.note, "Merke")

        let request = controller.noteRequest(for: item)
        XCTAssertEqual(request.text, "Merke")
        XCTAssertEqual(request.quote, item.quote)
        XCTAssertFalse(request.quote.isEmpty)
        grouped(undo) { request.save("Köbner-Phänomen\nzweite Zeile") }
        XCTAssertEqual(marks[0].1.contents, "Köbner-Phänomen\nzweite Zeile")
        undo.undo()
        XCTAssertEqual(marks[0].1.contents, "Merke")
        undo.redo()

        let saved = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(document.dataRepresentation())))
        let savedItem = try XCTUnwrap(noteItems(in: saved).first)
        XCTAssertEqual(savedItem.note, "Köbner-Phänomen\nzweite Zeile")
        XCTAssertEqual(savedItem.pairs.count, 3)
    }

    func testNoteAndColourSurviveTheSideFile() throws {
        let book = try paragraphDocument(pages: 3)
        let controller = PDFEditorController(document: book)
        controller.loadViewIfNeeded()
        let store = AnnotationSidecar(key: "notes", directory: directory)
        controller.sidecar = store
        let page = try XCTUnwrap(book.page(at: 1))
        let selection = try threeLineSelection(on: page)
        let marks = controller.markSelection(.highlight, note: "Merke", color: HighlightColor.sari.highlightColor,
                                             selection: selection)
        controller.recolor(marks, to: .yesil)
        controller.setNote("Köbner-Phänomen", on: marks[0].1)
        let snapshot = store.collect(from: book)
        store.write(pageCount: snapshot.pageCount, pages: snapshot.pages)

        let reopened = try paragraphDocument(pages: 3)
        XCTAssertTrue(AnnotationSidecar(key: "notes", directory: directory).apply(to: reopened))
        let items = noteItems(in: reopened)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.pageIndex, 1)
        XCTAssertEqual(items.first?.pairs.count, 3)
        XCTAssertEqual(items.first?.note, "Köbner-Phänomen")
        XCTAssertEqual(items.first.flatMap { NotesExport.color(of: $0) }, .yesil)
    }

    func testResultNotesAttachToThePassageOrThePage() throws {
        let document = try paragraphDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let (controller, undo) = editor(for: document)
        let selection = try threeLineSelection(on: page)

        grouped(undo) { controller.attachNote("Çeviri\nSchuppenflechte", to: .selection(selection)) }
        var notes = noteItems(in: document)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.kind, "Vurgu")
        XCTAssertEqual(notes.first?.pairs.count, 3)
        XCTAssertEqual(notes.first?.note, "Çeviri\nSchuppenflechte")

        // The same passage again extends that highlight's note instead of stacking a second highlight.
        grouped(undo) { controller.attachNote("Açıklama\nAutoimmun", to: .selection(selection)) }
        notes = noteItems(in: document)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.note, "Çeviri\nSchuppenflechte\n\nAçıklama\nAutoimmun")

        // A tapped mark gets the output as well.
        let mark = try XCTUnwrap(notes.first)
        grouped(undo) { controller.attachNote("Cevap\nJa", to: .mark(mark)) }
        XCTAssertEqual(noteItems(in: document).first?.note, "Çeviri\nSchuppenflechte\n\nAçıklama\nAutoimmun\n\nCevap\nJa")

        // A page result becomes a note icon, listed with its text and without a quote.
        grouped(undo) { controller.attachNote("Sayfa özeti\n- Plaques", to: .page(0)) }
        notes = noteItems(in: document)
        XCTAssertEqual(notes.count, 2)
        let pageNote = try XCTUnwrap(notes.last)
        XCTAssertEqual(pageNote.kind, "Not")
        XCTAssertEqual(pageNote.quote, "")
        XCTAssertEqual(pageNote.note, "Sayfa özeti\n- Plaques")
        undo.undo()
        XCTAssertEqual(noteItems(in: document).count, 1)
    }

    func testTapFindsTheWholeMark() throws {
        let document = try paragraphDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let (controller, undo) = editor(for: document)
        let selection = try threeLineSelection(on: page)
        let marks = grouped(undo) { controller.markSelection(.highlight, selection: selection) }
        let middle = marks[1].1.bounds
        let item = try XCTUnwrap(PDFEditorController.markItem(at: CGPoint(x: middle.midX, y: middle.midY), on: page, in: document))
        XCTAssertEqual(item.pairs.count, 3)
        XCTAssertTrue(item.pairs.contains { $0.1 === marks[0].1 })
        let below = try textLines(of: page)[6].bounds(for: page)
        XCTAssertNil(PDFEditorController.markItem(at: CGPoint(x: below.midX, y: below.midY), on: page, in: document))
    }

    func testPaletteReadsUnderEveryTint() {
        for color in HighlightColor.allCases {
            let tone = color.tone
            let paper = (tone.r, tone.g, tone.b)
            // Sepia multiplies the page tint (PageOverlayView); night inverts page and text.
            let sepia = (tone.r * 0.96, tone.g * 0.90, tone.b * 0.76)
            let night = (1 - tone.r, 1 - tone.g, 1 - tone.b)
            XCTAssertGreaterThan(contrast(paper, (0, 0, 0)), 7, "\(color.title) normal")
            XCTAssertGreaterThan(contrast(sepia, (0, 0, 0)), 7, "\(color.title) sepia")
            XCTAssertGreaterThan(contrast(night, (1, 1, 1)), 7, "\(color.title) night")
            XCTAssertEqual(HighlightColor.match(color.highlightColor), color)
            XCTAssertEqual(HighlightColor.match(color.lineColor), color)
            for other in HighlightColor.allCases where other != color {
                let dr = tone.r - other.tone.r
                let dg = tone.g - other.tone.g
                let db = tone.b - other.tone.b
                let d = (dr * dr + dg * dg + db * db).squareRoot()
                XCTAssertGreaterThan(d, 0.1, "\(color.title) and \(other.title) look alike")
            }
        }
        // Highlights made before the palette used systemYellow at half strength.
        XCTAssertEqual(HighlightColor.match(UIColor(red: 1, green: 0.8, blue: 0, alpha: 0.5)), .sari, "older highlights are yellow")
        XCTAssertNil(HighlightColor.match(.clear))
    }

    func testMarkdownExportGroupsByPageWithColour() throws {
        let document = try paragraphDocument(pages: 2)
        let (controller, undo) = editor(for: document)
        let first = try textLines(of: try XCTUnwrap(document.page(at: 0)))
        let second = try textLines(of: try XCTUnwrap(document.page(at: 1)))
        grouped(undo) { controller.markSelection(.highlight, note: "Merke", color: HighlightColor.yesil.highlightColor, selection: first[0]) }
        grouped(undo) { controller.markSelection(.underline, selection: first[2]) }
        grouped(undo) { controller.markSelection(.highlight, color: HighlightColor.pembe.highlightColor, selection: second[1]) }
        let markdown = NotesExport.markdown(noteItems(in: document))
        XCTAssertEqual(markdown.components(separatedBy: "## Sayfa 1\n").count, 2, markdown)
        XCTAssertEqual(markdown.components(separatedBy: "## Sayfa 2\n").count, 2, markdown)
        XCTAssertTrue(markdown.contains("**Vurgu** · Yeşil"), markdown)
        XCTAssertTrue(markdown.contains("**Altı çizili** · Mavi"), markdown)
        XCTAssertTrue(markdown.contains("**Vurgu** · Pembe"), markdown)
        XCTAssertTrue(markdown.contains("\n\nMerke"), "the note is a paragraph of its own after the quote")
        let firstPage = try XCTUnwrap(markdown.range(of: "## Sayfa 1"))
        let secondPage = try XCTUnwrap(markdown.range(of: "## Sayfa 2"))
        let pink = try XCTUnwrap(markdown.range(of: "· Pembe"))
        XCTAssertTrue(firstPage.lowerBound < secondPage.lowerBound && secondPage.lowerBound < pink.lowerBound)
    }
}

/// A page rendered at one pixel per point, annotations included.
private struct PageRaster {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let pageHeight: CGFloat

    init(_ page: PDFPage) throws {
        let box = page.bounds(for: .mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: box.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: box.size))
            context.cgContext.translateBy(x: -box.minX, y: box.height + box.minY)
            context.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let w = cgImage.width
        let h = cgImage.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drawn)
        pixels = buffer
        width = w
        height = h
        pageHeight = box.height
    }

    /// Average colour of a rectangle in page coordinates (origin bottom left).
    func average(in rect: CGRect) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let x0 = max(0, Int(rect.minX.rounded(.up)))
        let x1 = min(width, Int(rect.maxX.rounded(.down)))
        let y0 = max(0, Int((pageHeight - rect.maxY).rounded(.up)))
        let y1 = min(height, Int((pageHeight - rect.minY).rounded(.down)))
        guard x1 > x0, y1 > y0 else { return (-1, -1, -1) }
        var r = 0, g = 0, b = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                r += Int(pixels[i])
                g += Int(pixels[i + 1])
                b += Int(pixels[i + 2])
            }
        }
        let count = CGFloat((x1 - x0) * (y1 - y0)) * 255
        return (CGFloat(r) / count, CGFloat(g) / count, CGFloat(b) / count)
    }
}
