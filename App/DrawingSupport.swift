import PDFKit
import PencilKit
import UIKit

/// Drawings live as PencilKit data inside the PDF, one hidden annotation per page, in page units. Every pen
/// texture stays editable in OptiPDF; "Dışa aktar" burns the drawings into a copy for other apps.
enum DrawingStorage {
    static let marker = "OptiPDF.Drawing"
    private static let prefix = "OPTIPDF1|"

    static func isStorage(_ annotation: PDFAnnotation) -> Bool { annotation.userName == marker }

    /// The page as displayed: rotated pages swap width and height.
    static func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox).size
        return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }

    static func load(from page: PDFPage) -> PKDrawing? {
        guard let contents = page.annotations.first(where: { isStorage($0) })?.contents, contents.hasPrefix(prefix),
              let data = Data(base64Encoded: String(contents.dropFirst(prefix.count))) else { return nil }
        return try? PKDrawing(data: data)
    }

    static func save(_ drawing: PKDrawing, on page: PDFPage) {
        let existing = page.annotations.first(where: { isStorage($0) })
        guard !drawing.strokes.isEmpty else {
            if let existing { page.removeAnnotation(existing) }
            return
        }
        let contents = prefix + drawing.dataRepresentation().base64EncodedString()
        if let existing {
            existing.contents = contents
            return
        }
        let annotation = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 1, height: 1), forType: .freeText, withProperties: nil)
        annotation.userName = marker
        annotation.contents = contents
        annotation.shouldDisplay = false
        annotation.shouldPrint = false
        annotation.color = .clear
        annotation.fontColor = .clear
        page.addAnnotation(annotation)
    }
}

/// A page's canvas. PencilKit's own undo stack is kept local: undo runs through the document, one step per stroke.
final class PageCanvasView: PKCanvasView {
    weak var page: PDFPage?
    var strokeCount = 0
    var expectedData: Data?
    /// Set when the pencil starts drawing, erasing or moving strokes, cleared once that change is recorded.
    /// Drawings set by code (page reuse, sync after resizing, undo) never count as edits, so reading a page with
    /// a drawing no longer marks the document changed and triggers a save of the whole PDF.
    var userEditing = false
    var toolInUse = false
    var onResize: ((PageCanvasView) -> Void)?
    private var syncedWidth: CGFloat = 0
    private let localUndo: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 3
        return manager
    }()

    override var undoManager: UndoManager? { localUndo }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, abs(bounds.width - syncedWidth) > 0.5 else { return }
        syncedWidth = bounds.width
        onResize?(self)
    }
}

/// Draws a rendered drawing; used only for the flattened export.
final class DrawingImageAnnotation: PDFAnnotation {
    var image: UIImage?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cgImage = image?.cgImage else { return }
        context.saveGState()
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }
}

/// One canvas per page, shown by PDFKit above the page. In shape mode a finished stroke that looks like a line,
/// arrow, triangle, rectangle or ellipse is replaced by the clean shape.
final class DrawingOverlays: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    private(set) var canvases: [PDFPage: PageCanvasView] = [:]
    private var stored: [PDFPage: PKDrawing] = [:]
    private var loadedPages: Set<PDFPage> = []
    weak var toolPicker: PKToolPicker?
    var snapShapes = false
    /// Page, previous drawing, new drawing (page units) after a user edit.
    var onChange: ((PDFPage, PKDrawing, PKDrawing) -> Void)?
    private var drawingEnabled = false
    private var programmatic = false

    func load(_ page: PDFPage) {
        guard loadedPages.insert(page).inserted else { return }
        if let drawing = DrawingStorage.load(from: page) { stored[page] = drawing }
    }

    func drawing(for page: PDFPage) -> PKDrawing? {
        load(page)
        return stored[page]
    }

    func setDrawing(_ enabled: Bool) {
        drawingEnabled = enabled
        for canvas in canvases.values { canvas.isUserInteractionEnabled = enabled }
    }

    /// Replaces a page's drawing without recording a user edit (undo and redo).
    func replace(_ drawing: PKDrawing, for page: PDFPage) {
        loadedPages.insert(page)
        stored[page] = drawing
        if let canvas = canvases[page] { sync(canvas) }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        load(page)
        let canvas = canvases[page] ?? makeCanvas()
        attach(canvas, to: page)
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PageCanvasView else { return }
        attach(canvas, to: page)
        sync(canvas)
    }

    /// A page that scrolls away gives up its canvas; its drawing stays in `stored`. Keeping one canvas per
    /// visited page made long PDFs grow in memory until scrolling stalled.
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PageCanvasView, canvases[page] === canvas else { return }
        toolPicker?.removeObserver(canvas)
        canvases[page] = nil
    }

    private func attach(_ canvas: PageCanvasView, to page: PDFPage) {
        canvases[page] = canvas
        canvas.page = page
        canvas.isUserInteractionEnabled = drawingEnabled
        if let toolPicker {
            toolPicker.addObserver(canvas)
            canvas.tool = toolPicker.selectedTool
        }
    }

    /// Canvas points per page unit.
    func scale(of canvas: PageCanvasView) -> CGFloat {
        guard let page = canvas.page else { return 1 }
        let size = DrawingStorage.displaySize(of: page)
        guard size.width > 0, canvas.bounds.width > 1 else { return 1 }
        return canvas.bounds.width / size.width
    }

    private func sync(_ canvas: PageCanvasView) {
        guard let page = canvas.page, canvas.bounds.width > 1 else { return }
        let s = scale(of: canvas)
        let wanted = (drawing(for: page) ?? PKDrawing()).transformed(using: CGAffineTransform(scaleX: s, y: s))
        set(wanted, on: canvas)
    }

    private func set(_ drawing: PKDrawing, on canvas: PageCanvasView) {
        if canvas.drawing.strokes.isEmpty && drawing.strokes.isEmpty { return }
        if canvas.drawing.dataRepresentation() == drawing.dataRepresentation() { return }
        canvas.expectedData = drawing.dataRepresentation()
        programmatic = true
        canvas.drawing = drawing
        programmatic = false
        canvas.strokeCount = drawing.strokes.count
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? PageCanvasView else { return }
        canvas.toolInUse = true
        canvas.userEditing = true
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? PageCanvasView else { return }
        canvas.toolInUse = false
        // The stroke's drawing change can arrive just after the tool ends; stop counting changes shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak canvas] in
            if let canvas, !canvas.toolInUse { canvas.userEditing = false }
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !programmatic, let canvas = canvasView as? PageCanvasView, canvas.userEditing,
              let page = canvas.page, canvas.bounds.width > 1 else { return }
        defer { if !canvas.toolInUse { canvas.userEditing = false } }
        if let expected = canvas.expectedData {
            if expected == canvas.drawing.dataRepresentation() { return }
            canvas.expectedData = nil
        }
        var current = canvas.drawing
        if snapShapes, current.strokes.count == canvas.strokeCount + 1, let last = current.strokes.last,
           let perfect = ShapeRecognizer.perfected(last) {
            var strokes = current.strokes
            strokes[strokes.count - 1] = perfect
            current = PKDrawing(strokes: strokes)
            set(current, on: canvas)
        }
        canvas.strokeCount = current.strokes.count
        let s = scale(of: canvas)
        let updated = current.transformed(using: CGAffineTransform(scaleX: 1 / s, y: 1 / s))
        let previous = stored[page] ?? PKDrawing()
        if previous.strokes.isEmpty && updated.strokes.isEmpty { return }
        guard previous.dataRepresentation() != updated.dataRepresentation() else { return }
        stored[page] = updated
        onChange?(page, previous, updated)
    }

    private func makeCanvas() -> PageCanvasView {
        let canvas = PageCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // iPad: the pencil draws and fingers scroll. iPhone has no pencil, so a finger draws.
        canvas.drawingPolicy = UIDevice.current.userInterfaceIdiom == .phone ? .anyInput : .pencilOnly
        canvas.isScrollEnabled = false
        canvas.delegate = self
        canvas.onResize = { [weak self] canvas in self?.sync(canvas) }
        return canvas
    }
}
